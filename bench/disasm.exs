# Disassemble FastDecimal hot-path functions to inspect the BEAM bytecode that
# BEAMAsm (the JIT) sees.
#
# Run with: `mix run bench/disasm.exs`
#
# Things we look for in the output:
#   - `put_map_exact`   — fast, updates an existing map's value for a known key
#   - `put_map_assoc`   — slower, allocates a fresh map (returns from struct literal)
#   - `gc_bif`          — calls a BIF that may GC (arithmetic ops do this)
#   - `get_map_element` — map lookup; cheaper than a generic call but not free
#   - `is_map` + `is_eq_exact` on `__struct__` — struct type guard pattern
#
# The dump for `add/2` was the headline finding: each successful clause ended in
# `put_map_assoc` (fresh-map construction), which is what motivated the
# `%{a | coef: ...}` rewrite in lib/fastdecimal.ex. After that rewrite, the
# dump shows `put_map_exact` instead — re-run this script to confirm.

beam_path = :code.which(FastDecimal)

{:beam_file, _module, _exports, _attrs, _compile_info, code} = :beam_disasm.file(beam_path)

functions_of_interest = [
  {:add, 2},
  {:sub, 2},
  {:mult, 2},
  {:compare, 2},
  {:negate, 1},
  {:abs, 1},
  {:zero?, 1}
]

IO.puts("\n== BEAM bytecode for hot-path functions ==\n")

for {fun_name, fun_arity} <- functions_of_interest do
  case Enum.find(code, fn {:function, name, arity, _entry, _instrs} ->
         name == fun_name and arity == fun_arity
       end) do
    {:function, name, arity, _entry, instrs} ->
      IO.puts("\n--- #{name}/#{arity} (#{length(instrs)} ops) ---")

      for instr <- instrs do
        IO.puts("  #{inspect(instr, limit: :infinity, printable_limit: :infinity)}")
      end

    nil ->
      IO.puts("\n--- #{fun_name}/#{fun_arity}: NOT FOUND ---")
  end
end

# Quick summary: count `put_map_assoc` vs `put_map_exact` calls across the module.
all_instrs =
  for {:function, _, _, _, instrs} <- code,
      instr <- instrs do
    instr
  end

count = fn pat ->
  Enum.count(all_instrs, fn
    {pat_, _f, _bs, _src, _live, _list} when pat_ == pat -> true
    _ -> false
  end)
end

IO.puts("\n== Map-construction op counts (module-wide) ==")
IO.puts("  put_map_assoc: #{count.(:put_map_assoc)} (each allocates a fresh map)")
IO.puts("  put_map_exact: #{count.(:put_map_exact)} (each updates an existing map)")
