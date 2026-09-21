# A timing report as JSON, for a tool to read. The report is written whole but for
# what it holds twice: every condition and path says itself whether the budget
# rejects it or leaves it alone, so the lists of those are not written again.

const TIMING_JSON_VERSION = 1

function _writejson(io::IO, r::TimingReport)
  budget = (; max_bits=[[n, bits] for (n, bits) in r.budget.max_bits], max_carry=r.budget.max_carry,
            max_chain=r.budget.max_chain, reject=r.budget.custom)
  JSON.json(io, (; version=TIMING_JSON_VERSION, top=string(nameof(r.top)), lut_inputs=r.lut_inputs, depth=r.depth, flow=r.flow,
                 ok=r.ok, budget,
                 excluded=r.excluded, conditions=r.conditions, paths=r.paths,
                 rejectedpaths=[(; p.from, p.to) for p in r.rejectedpaths],
                 exemptpaths=[(; p.from, p.to) for p in r.exemptpaths]))
  println(io)
end
