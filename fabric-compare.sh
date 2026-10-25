#!/bin/sh
#
# fabric-compare.sh — put both sides of a redundant SAN fabric on one page.
#
# A storage fabric is built as a redundant pair, A and B. The redundancy only
# holds if the two sides are equivalent. This renders them side by side so you
# can see at a glance whether they are.
#
# Two join strategies are provided, deliberately:
#
#   --join row    Glue the two CSVs together line by line with paste(1).
#                 This is what the original 2011 script did. It is correct
#                 only while both sides produce identical line counts in
#                 identical order. When they do not, every row below the
#                 divergence compares two different ports, silently.
#
#   --join port   Full outer join on port index. Ports present on one side
#                 and not the other are reported as asymmetries, which is
#                 the entire thing you are looking for.
#
# Two presentations are provided, also deliberately:
#
#   --style classic   A bordered HTML table, close to what the 2011 original
#                     emitted. Readable, ugly, and it did the job for years.
#
#   --style modern    The same data as it would be presented today. Nothing
#                     about the comparison changes; only the rendering does.
#
# Run it both ways against the bundled sample data to see the difference.
#
# Usage:
#   ./fabric-compare.sh                                  # sample data, port join
#   ./fabric-compare.sh --join row                       # reproduce the old bug
#   ./fabric-compare.sh --style modern                   # present-day rendering
#   ./fabric-compare.sh --live --data /path/to/conf      # collect over ssh
#
# No warranty. Sample data is synthetic; addresses are from 192.0.2.0/24
# (TEST-NET-1, reserved for documentation) and no WWN belongs to real hardware.

set -eu

FABRIC="fab01"
JOIN="port"
STYLE="classic"
DATA="sample-data"
OUT=""
LIVE=0

usage() {
    sed -n '2,42p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --fabric) FABRIC="$2"; shift 2 ;;
        --join)   JOIN="$2";   shift 2 ;;
        --style)  STYLE="$2";  shift 2 ;;
        --data)   DATA="$2";   shift 2 ;;
        --out)    OUT="$2";    shift 2 ;;
        --live)   LIVE=1;      shift ;;
        -h|--help) usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

case "$JOIN" in
    row|port) ;;
    *) echo "--join must be 'row' or 'port'" >&2; exit 1 ;;
esac

case "$STYLE" in
    classic|modern) ;;
    *) echo "--style must be 'classic' or 'modern'" >&2; exit 1 ;;
esac

[ -n "$OUT" ] || OUT="${FABRIC}_${STYLE}_${JOIN}.html"

LIST="$DATA/switch_list"
[ -f "$LIST" ] || { echo "no switch list at $LIST" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# ---------------------------------------------------------------------------
# Look up the switch on each side of this fabric.
# switch_list columns: side  switch_name  address  fabric
# ---------------------------------------------------------------------------

lookup() {
    awk -v side="$1" -v fab="$2" -v col="$3" \
        '$0 !~ /^#/ && NF >= 4 && $1 == side && $4 == fab { print $col; exit }' "$LIST"
}

SW_A=$(lookup A "$FABRIC" 2); IP_A=$(lookup A "$FABRIC" 3)
SW_B=$(lookup B "$FABRIC" 2); IP_B=$(lookup B "$FABRIC" 3)

[ -n "$SW_A" ] || { echo "no side A switch for fabric $FABRIC" >&2; exit 1; }

if [ -z "$SW_B" ]; then
    echo "warning: fabric $FABRIC has no side B switch; rendering single width" >&2
fi

# ---------------------------------------------------------------------------
# Collect. Either read the bundled captures, or go and ask the switches.
#
# The live path runs the same three commands the 2011 script did. It is
# provided because collection is the point of the tool, but it has only been
# exercised against the sample captures in this repo, not against hardware.
# ---------------------------------------------------------------------------

collect() {
    side="$1"; sw="$2"; ip="$3"
    [ -n "$sw" ] || return 0
    if [ "$LIVE" -eq 1 ]; then
        ssh "admin@$ip" switchshow     > "$WORK/${side}.switchshow"
        ssh "admin@$ip" "alishow '*'"  > "$WORK/${side}.alishow"
    else
        cp "$DATA/${FABRIC}_${side}.switchshow" "$WORK/${side}.switchshow"
        cp "$DATA/${FABRIC}_${side}.alishow"    "$WORK/${side}.alishow"
    fi
}

collect a "$SW_A" "$IP_A"
collect b "$SW_B" "$IP_B"

# ---------------------------------------------------------------------------
# Parse one side into: index,switch,port,alias,wwn,state
#
# The original stripped the switchshow header by listing every header string
# it knew about and grepping them out, which breaks quietly when a firmware
# release adds a new one. Keying off the ===== separator is both shorter and
# does not care what the header contains.
# ---------------------------------------------------------------------------

parse_side() {
    side="$1"; sw="$2"
    [ -f "$WORK/${side}.switchshow" ] || { : > "$WORK/${side}.csv"; return 0; }
    awk -v sw="$sw" '
        # First file: the alias table. Build wwn -> alias.
        NR == FNR {
            if ($1 == "alias:")                        { name = $2 }
            else if ($1 ~ /^[0-9a-fA-F][0-9a-fA-F]:/)  { amap[tolower($1)] = name }
            next
        }
        # Second file: switchshow. Everything after ===== is a port.
        /^=+$/ { body = 1; next }
        !body || NF == 0 { next }
        {
            idx = $1; port = $2; state = $6
            wwn = (NF >= 9) ? $9 : ""
            alias = ""
            if (wwn != "" && tolower(wwn) in amap) alias = amap[tolower(wwn)]
            if (alias == "" && NF >= 8 && $8 == "E-Port") alias = "(ISL)"
            if (alias == "") alias = "-"
            if (wwn == "")   wwn   = "-"
            print idx "," sw "," port "," alias "," wwn "," state
        }
    ' "$WORK/${side}.alishow" "$WORK/${side}.switchshow" > "$WORK/${side}.csv"
}

parse_side a "$SW_A"
parse_side b "$SW_B"

PORTS_A=$(wc -l < "$WORK/a.csv" | tr -d ' ')
PORTS_B=$(wc -l < "$WORK/b.csv" | tr -d ' ')
FREE_A=$(grep -c ',No_Light$' "$WORK/a.csv" || true)
FREE_B=$(grep -c ',No_Light$' "$WORK/b.csv" || true)

# ---------------------------------------------------------------------------
# Join. Output is 13 fields: six for A, six for B, then a flag.
# ---------------------------------------------------------------------------

if [ "$JOIN" = "row" ]; then
    # The 2011 behaviour: lay the two files next to each other and hope the
    # line numbers correspond to the same port. The MISALIGNED flag is a
    # diagnostic added here to make the failure visible — the original had
    # no way to know, which is exactly the problem with it.
    #
    # Pad the shorter side first. paste(1) on its own emits a short record
    # when one file runs out, which shifts every later column left by six
    # and quietly corrupts the output a second way.
    if [ "$PORTS_A" -gt "$PORTS_B" ]; then LONG="$PORTS_A"; else LONG="$PORTS_B"; fi
    pad_to() {
        cur=$(wc -l < "$1" | tr -d ' ')
        while [ "$cur" -lt "$2" ]; do printf ',,,,,\n' >> "$1"; cur=$((cur + 1)); done
    }
    pad_to "$WORK/a.csv" "$LONG"
    pad_to "$WORK/b.csv" "$LONG"

    paste -d, "$WORK/a.csv" "$WORK/b.csv" \
    | awk -F, -v OFS=, '{
        flag = ""
        if ($1 == "" || $7 == "")      flag = "RAN_OUT"
        else if ($1 + 0 != $7 + 0)     flag = "MISALIGNED"
        print $0, flag
      }' > "$WORK/joined.csv"
else
    # Join on the port index, which is the key the data actually has.
    awk -F, -v OFS=, '
        NR == FNR { a[$1 + 0] = $0; if ($1 + 0 > max) max = $1 + 0; next }
                  { b[$1 + 0] = $0; if ($1 + 0 > max) max = $1 + 0 }
        END {
            for (i = 0; i <= max; i++) {
                ina = (i in a); inb = (i in b)
                if (!ina && !inb) continue
                la = ina ? a[i] : ",,,,,"
                lb = inb ? b[i] : ",,,,,"
                flag = (ina && inb) ? "" : (ina ? "A_ONLY" : "B_ONLY")
                print la, lb, flag
            }
        }
    ' "$WORK/a.csv" "$WORK/b.csv" > "$WORK/joined.csv"
fi

ASYM=$(awk -F, '$13 != "" { n++ } END { print n + 0 }' "$WORK/joined.csv")

# ---------------------------------------------------------------------------
# Render.
# ---------------------------------------------------------------------------

awk -F, \
    -v fabric="$FABRIC" -v mode="$JOIN" -v generated="$(date -u '+%Y-%m-%d %H:%M UTC')" \
    -v swa="$SW_A" -v swb="${SW_B:-(none)}" \
    -v pa="$PORTS_A" -v pb="$PORTS_B" -v fa="$FREE_A" -v fb="$FREE_B" -v asym="$ASYM" \
    -v style="$STYLE" '
BEGIN {
    pagename = (style == "modern") ? "Port Reservation Details" : "Port Reservation Sheet"
    print "<!doctype html>"
    print "<html lang=\"en\"><head><meta charset=\"utf-8\">"
    print "<title>" pagename " — " toupper(fabric) "</title>"
    print "<style>"
    if (style == "modern") {
        print "  :root{--a:#d97706;--b:#2563eb}"
        print "  *{box-sizing:border-box}"
        print "  body{margin:0;padding:28px 20px;background:#f1f5f9;color:#0f172a;"
        print "       font:14px/1.5 -apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Helvetica,Arial,sans-serif}"
        print "  .wrap{max-width:1320px;margin:0 auto}"
        print "  header{background:#fff;border:1px solid #e2e8f0;border-left:4px solid var(--a);"
        print "         border-radius:10px;padding:18px 22px;margin-bottom:16px}"
        print "  header h1{margin:0;font-size:19px;font-weight:650;letter-spacing:-.01em}"
        print "  header p{margin:4px 0 0;color:#64748b;font-size:13px}"
        print "  .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:16px}"
        print "  .card{background:#fff;border:1px solid #e2e8f0;border-radius:10px;padding:16px;text-align:center}"
        print "  .card b{display:block;font-size:26px;font-weight:650;letter-spacing:-.02em}"
        print "  .card span{font-size:12px;color:#64748b}"
        print "  .card.warn{border-color:#fecaca;background:#fef2f2} .card.warn b{color:#dc2626}"
        print "  .card.ok b{color:#16a34a}"
        print "  .panel{background:#fff;border:1px solid #e2e8f0;border-radius:10px;overflow-x:auto}"
        print "  table{border-collapse:collapse;width:100%;font-size:12.5px}"
        print "  th,td{padding:7px 10px;text-align:left;white-space:nowrap;border-bottom:1px solid #f1f5f9}"
        print "  thead th{background:#f8fafc;color:#475569;font-weight:600;font-size:11px;"
        print "           letter-spacing:.04em;text-transform:uppercase}"
        print "  thead th.side{color:#fff;text-align:center;font-size:12px}"
        print "  th.side.a{background:var(--a)} th.side.b{background:var(--b)}"
        print "  .gap{border-left:2px solid #e2e8f0}"
        print "  tbody tr:nth-child(even) td{background:#fcfcfd}"
        print "  tbody tr.asym td{background:#fffbeb}"
        print "  tbody tr.bad  td{background:#fef2f2}"
        print "  .pill{display:inline-block;padding:2px 9px;border-radius:999px;font-size:11px;font-weight:600}"
        print "  .pill.on{background:#dcfce7;color:#166534} .pill.off{background:#f1f5f9;color:#94a3b8}"
        print "  td.flag{font-weight:700;font-size:10.5px;letter-spacing:.04em;color:#dc2626}"
        print "  .dark{color:#cbd5e1}"
        print "  .note{background:#fff;border:1px solid #e2e8f0;border-left:4px solid var(--a);"
        print "        border-radius:10px;padding:14px 18px;margin:16px 0;color:#475569;font-size:13px}"
        print "  .note strong{color:#0f172a}"
    } else {
        print "  body{font:13px Verdana,Arial,sans-serif;margin:20px;color:#000;background:#fff}"
        print "  h1{font-style:italic;text-align:center;color:#FF8C00;text-decoration:underline;"
        print "     font-size:28px;margin:0 0 6px}"
        print "  .sub{text-align:center;color:#444;font-size:12px;margin-bottom:10px}"
        print "  .stats{text-align:center;font-size:12px;margin-bottom:14px}"
        print "  .stats b{color:#000}"
        print "  table{border-collapse:collapse;margin:0 auto;font-size:11px}"
        print "  th,td{border:1px solid #000;padding:2px 6px;text-align:center;white-space:nowrap}"
        print "  thead th{background:#d9d9d9}"
        print "  th.side{background:#FF8C00;color:#fff}"
        print "  .online{color:#008000;font-weight:bold}"
        print "  .dark{color:#808080}"
        print "  tr.asym td{background:#ffe9b3}"
        print "  tr.bad  td{background:#ffd0cc}"
        print "  td.flag{font-weight:bold;font-size:10px}"
        print "  .note{max-width:900px;margin:14px auto;font-size:12px;border:1px solid #999;"
        print "        padding:8px;background:#f8f8f8}"
    }
    print "</style></head><body>"

    if (style == "modern") {
        print "<div class=\"wrap\">"
        print "<header>"
        print "  <h1>" pagename "</h1>"
        print "  <p>Fabric " toupper(fabric) " &middot; generated " generated \
              " &middot; join mode: " mode "</p>"
        print "</header>"

        print "<div class=\"cards\">"
        print "  <div class=\"card\"><b>" pa "</b><span>ports on A</span></div>"
        print "  <div class=\"card\"><b>" fa "</b><span>free on A</span></div>"
        print "  <div class=\"card\"><b>" pb "</b><span>ports on B</span></div>"
        print "  <div class=\"card\"><b>" fb "</b><span>free on B</span></div>"
        print "  <div class=\"card " (asym > 0 ? "warn" : "ok") "\"><b>" asym "</b><span>" \
              (mode == "port" ? "asymmetries" : "bad rows") "</span></div>"
        print "</div>"
    } else {
        print "<h1>" pagename "</h1>"
        print "<div class=\"sub\">Fabric " toupper(fabric) " &nbsp;&middot;&nbsp; generated " generated \
              " &nbsp;&middot;&nbsp; join mode: <strong>" mode "</strong></div>"
        print "<div class=\"stats\">A: <b>" pa "</b> ports, <b>" fa "</b> free" \
              " &nbsp;&middot;&nbsp; B: <b>" pb "</b> ports, <b>" fb "</b> free" \
              " &nbsp;&middot;&nbsp; <b>" asym "</b> " (mode == "port" ? "asymmetries" : "bad rows") "</div>"
    }

    if (mode == "row" && asym > 0) {
        print "<div class=\"note\"><strong>This page is lying to you.</strong> Rows were paired by"
        print "line number, not by port. The two sides diverge, so from that point on each row puts"
        print "one port next to a different port. The highlighted rows show where — but the original"
        print "script had no such check, which is the whole problem: the page rendered, looked"
        print "authoritative, and was wrong. Re-run with <code>--join port</code>.</div>"
    }

    if (style == "modern") print "<div class=\"panel\">"
    print "<table><thead>"
    print "<tr><th class=\"side a\" colspan=\"6\">FABRIC A &nbsp;&mdash;&nbsp; " swa "</th>" \
          "<th class=\"side b gap\" colspan=\"6\">FABRIC B &nbsp;&mdash;&nbsp; " swb "</th>" \
          "<th class=\"side\">&nbsp;</th></tr>"
    print "<tr><th>Index</th><th>Switch</th><th>Port</th><th>Alias</th><th>PWWN</th><th>State</th>" \
          "<th class=\"gap\">Index</th><th>Switch</th><th>Port</th><th>Alias</th><th>PWWN</th><th>State</th>" \
          "<th>Note</th></tr>"
    print "</thead><tbody>"
}

function cell(v, extra,   cls) {
    if (v == "") { printf "<td class=\"dark %s\">&middot;</td>", extra; return }
    if (style == "modern" && (v == "Online" || v == "No_Light")) {
        printf "<td class=\"%s\"><span class=\"pill %s\">%s</span></td>", extra, \
               (v == "Online" ? "on" : "off"), (v == "Online" ? "Online" : "No Light")
        return
    }
    cls = extra
    if (v == "Online")   cls = cls " online"
    if (v == "No_Light") cls = cls " dark"
    printf "<td class=\"%s\">%s</td>", cls, v
}

{
    rowcls = ""
    if ($13 == "MISALIGNED" || $13 == "RAN_OUT") rowcls = " class=\"bad\""
    else if ($13 != "")                          rowcls = " class=\"asym\""
    printf "<tr%s>", rowcls
    for (i = 1; i <= 6; i++)  cell($i, "")
    for (i = 7; i <= 12; i++) cell($i, (i == 7 ? "gap" : ""))
    printf "<td class=\"flag\">%s</td>", ($13 == "" ? "" : $13)
    print "</tr>"
}

END {
    print "</tbody></table>"
    if (style == "modern") print "</div>"
    print "<div class=\"note\">Synthetic sample data. Addresses are TEST-NET-1; no WWN"
    print "belongs to real hardware. <code>A_ONLY</code> / <code>B_ONLY</code> mean the port"
    print "exists on one side of the pair and not the other &mdash; that is an asymmetry in a design"
    print "whose entire value is symmetry, and it is what you came here to find.</div>"
    if (style == "modern") print "</div>"
    print "</body></html>"
}
' "$WORK/joined.csv" > "$OUT"

echo "fabric    : $FABRIC"
echo "side A    : $SW_A  ($PORTS_A ports, $FREE_A free)"
echo "side B    : ${SW_B:-(none)}  ($PORTS_B ports, $FREE_B free)"
echo "join mode : $JOIN"
if [ "$JOIN" = "port" ]; then
    echo "asymmetry : $ASYM port(s) present on one side only"
else
    echo "bad rows  : $ASYM row(s) comparing mismatched ports"
fi
echo "written   : $OUT"
