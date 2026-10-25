# What an API-backed version looks like

**What's in this repo:** a shell script that runs `switchshow` and `alishow`, parses the text, and writes an HTML page. That is deliberate — it mirrors what the 2011 original did, because the article this repo accompanies is about why that original was wrong in a way nobody could see.

**What this document is:** what I'd build instead if I were starting today, and what actually changes when you do. The `--style modern` rendering in this repo is cosmetic — it's the same scraped text in nicer CSS. It is not an API version, and I don't want anyone reading the screenshots and concluding otherwise. The real differences are below the presentation layer, and they're the interesting ones.

## Scraping and polling are not the same problem

The 2011 script ran, collected, rendered and published in one pass. The page *was* the collection run. If you wanted today's state you re-ran the script; if the script failed halfway, you got half a page.

That coupling causes most of the bugs. Pull them apart and you get three separable pieces:

1. **Collection** — talk to each switch, on a schedule, and write what it said into a store, with a timestamp and an outcome.
2. **Comparison** — read the store, pair A against B, decide what counts as an asymmetry.
3. **Presentation** — render the comparison.

Only the first one cares what the hardware speaks. Everything above it works on records.

## Absence of data stops looking like data

This is the single biggest win, and it has nothing to do with REST versus SSH.

In the scraped version, an unreachable switch produces no output. No output parses into zero ports. Zero ports renders as an empty column, and an empty column looks exactly like a switch with nothing plugged into it. The page tells you a fabric side is empty when what actually happened is that nobody could reach it. It publishes a failure as a finding.

With a call that returns a status, you can tell the two apart, because you get an answer either way — a result, or a reason there isn't one. So the page can say *"side B: not collected, 2 hours stale, last attempt refused"* instead of silently drawing an empty table. Half the value of moving off text scraping is just that failure becomes representable.

You can retrofit this onto the shell version — check the exit status, write a sentinel, render it. It's just that nothing forces you to, and so for years nobody did.

## The join key gets better, not just easier

The comparison in this repo joins on port index: A port 7 pairs with B port 7. That's already a real improvement on joining by line number, which is what the original did and what `--join row` demonstrates going wrong.

But port index is still a proxy. It assumes the two switches are laid out the same way, which is true right up until the pair isn't identical hardware, or someone recables one side, or one switch has a block of ports that isn't licensed. Port index means *"the same position"*, and what you actually want to know is *"the same thing"*.

A structured source gives you device identity directly — the WWN, and whatever the fabric knows about what's behind it. Join on that and the question changes shape. Instead of *"does A have something in slot 7 like B does"* you're asking *"this device claims two paths; can I see both of them, on different fabrics?"* That is the question the redundancy design is actually making a promise about. Port index was only ever standing in for it.

That reframing matters more than the transport. You could do it with scraped text — the WWN is right there in `switchshow` and this script already parses it. I didn't, because the point of this repo is to show the 2011 shape of the problem, not to be the best version of the tool.

## What doesn't change

You still have to decide what "equivalent" means, and nothing will decide it for you.

Is a host with one path a fault, or a known exception that someone signed off? Is a port count mismatch a problem, or just a bigger switch on one side with room to grow? Is an ISL asymmetry interesting? Every one of those is a local policy judgement, and it's the part that no vendor ships, because it isn't a fact about any single box — it's a fact about the relationship between two of them, and the relationship doesn't have an owner.

An API gets you cleaner inputs. It doesn't get you the answer. The rules still have to be written down by someone who knows the estate, and they still go stale when the estate changes.

## So what's actually worth doing

If you're carrying something like the 2011 script right now, in rough order of payoff:

- **Make failure visible.** Distinguish "collected, empty" from "did not collect". Put the collection time on the page. This is an afternoon and it removes the worst failure mode.
- **Stop joining on position.** Line number is indefensible; port index is defensible but still a proxy. Device identity is the real key.
- **Split collection from rendering.** Once the two are separate, the page can be stale-but-honest instead of broken, and you can re-render without re-polling.
- **Then, if you want, make it pretty.** It's the easiest part and the one with the least bearing on whether the output is true.

The ordering is the point. Presentation is the thing that improved on its own over fifteen years — browsers got better whether or not I did anything. Everything above it is still work, and it's still the same work it was in 2011.
