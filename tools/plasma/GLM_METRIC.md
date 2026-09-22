# A2. GLM divergence cleaning: success metric, written before implementing

**Date:** 2026-08-30
**Rule being followed:** define success in user-facing terms BEFORE building, and
validate any gain on a several-times-wider ruler than the one it was tuned on.
(`feedback_reward_must_be_robust`, `feedback_dont_claim_unmeasured`.)

## The problem

`stdlib/mhd_kernel.rail` carries two integrators over the same 6-field state:

| path | order | max&#124;div B&#124; after 100 steps | used by |
|---|---|---|---|
| Lax-Friedrichs | 1st | 5.7e-15 (machine precision) | the live entropy beacon |
| MUSCL + minmod + Rusanov | 2nd | **0.174** | nothing, because of this |

MUSCL resolves the Orszag-Tang vortex far better (1.76x the peak density at
matched simulation time) but does not preserve div B = 0 on a cell-centered
Cartesian grid. Magnetic monopoles do not exist; a scheme that manufactures them
is evolving a fluid that is not a plasma. So the sharper integrator is unusable
for the public beacon, and the beacon ships the blunt one.

Suite test `t187 mhd_muscl_divb_regression` currently pins that dirtiness as a
bounded fact so the paths cannot be swapped by accident.

## What "success" means

Dedner-style GLM cleaning adds a scalar field psi that transports divergence
error out of the cells and damps it. The target is a **usable second-order
path**, not a smaller number in isolation.

### Primary (the gate)

1. **Divergence.** max&#124;div B&#124; at 100 steps must be **>= 10x lower** than
   plain MUSCL at the same step count. Plain MUSCL measures 0.174, so GLM must
   reach <= 1.74e-2. (Machine precision is not the goal and would be suspicious:
   GLM controls divergence, it does not eliminate it the way LF's flux structure
   accidentally does.)
2. **Conservation must not be spent to buy it.** &#124;dm/m&#124; and
   &#124;dE/E&#124; must stay <= 1e-10 over the window, the same bar t186 holds
   Lax-Friedrichs to.
3. **The sharpness must survive.** rho_max(GLM-MUSCL) must stay **>= rho_max(LF)**
   at matched simulation time. If cleaning costs the resolution, it has bought
   nothing: LF is already divergence-clean and cheaper.

### Secondary (reported, not gated)

- Cost: wall-clock per step vs plain MUSCL.
- The shape of the div B curve over the window, not just its endpoint.

## The wider ruler (this is the part that matters)

Any damping coefficient will be tuned against the 100-step window. A coefficient
fitted to 100 steps that fails at 400 is exactly the window-overfitting that
invalidated the entire attested self-improvement climb in July.

So the gate is **re-measured on a disjoint, wider window before any claim**:

- **Tune on:** 100 steps, standard Orszag-Tang IC.
- **Validate on:** 400 steps (4x), AND a seeded-perturbed IC via
  `mk_perturb_seed` with a seed the tuning never saw.

A result that only holds at 100 steps on the unperturbed IC is reported as a
failure, not as a result.

## Abort condition

If the div B reduction cannot reach 10x without violating conservation or losing
the sharpness advantage, **stop and report that**. A second-order path that
trades monopoles for a blunt solution is not worth landing, and "we tried GLM and
it did not pay for itself on this grid" is a real finding.

---

# RESULTS (2026-08-30)

**Verdict: the gate is met, and it holds on the wider ruler.** Landed as
`mk_muscl_glm_step` in `stdlib/mhd_kernel.rail`, pinned by suite test
`t189 mhd_glm_divergence_cleaning`.

## Configuration found

| knob | value | why |
|---|---|---|
| `ch_mult` | 3.0 | c_h as a multiple of the signal speed. dx/dt = 3.333 smax is both the physical maximum and the symplectic stability limit, so this sits just inside it. |
| `cr` | 0.18 | damping length |
| substeps | 4 | cleaning substeps per MHD step |

## The gate, on the 100-step tuning window

| | plain MUSCL | GLM | ratio |
|---|---|---|---|
| max&#124;div B&#124; | 0.174 | **0.01265** | **13.8x** |
| rms&#124;div B&#124; | 0.01843 | 0.001146 | 16.1x |
| &#124;dm/m&#124; | 2.3e-13 | 2.3e-13 | unchanged |
| &#124;dE/E&#124; | 6.1e-15 | 7.1e-15 | unchanged |
| rho_max | 6.2575 | 6.2587 | preserved (LF: 3.5495) |

All three primary criteria pass: >= 10x divergence reduction, conservation at
1e-13, sharpness intact at 1.76x LF.

## The wider ruler: 400 steps (4x) and an IC the tuning never saw

| run | plain max&#124;div B&#124; | GLM max&#124;div B&#124; | ratio | GLM rho_max | LF rho_max |
|---|---|---|---|---|---|
| 400 steps, standard IC | 1.3431 | **0.0874** | **15.4x** | 5.866 | 4.369 |
| 400 steps, seed 777001 | 1.3164 | **0.0896** | **14.7x** | 5.902 | 4.367 |

The gain does not merely survive the 4x window, it **grows** (13.8x -> 15.4x),
which is the expected sign: plain MUSCL's divergence keeps climbing while GLM
holds it near a bounded equilibrium. It reproduces on a seeded initial
condition that played no part in choosing the knobs. Conservation stays at
2.4e-13 / 8.7e-15 in every case.

## What the tuning taught, beyond the number

Raising the divergence-wave speed barely helped on its own:

| ch_mult | cr | max&#124;div B&#124; @100 | ratio |
|---|---|---|---|
| 1.0 | 0.5 | 0.0334 | 5.2x |
| 2.0 | 0.5 | 0.0334 | 5.2x |
| 3.0 | 0.5 | 0.0391 | 4.5x |
| 3.0 | 0.18 | 0.0284 | 6.1x |
| 3.0 (x4 substeps) | 0.18 | **0.01265** | **13.8x** |

Cleaning settles into a balance against the rate the MUSCL flux *generates*
divergence. Transport speed alone cannot beat a source term; **cleaning
frequency** is the knob that does. That is why the first three rows plateau
near 0.033 regardless of c_h, and why substepping is what broke through.

## Cost

100 steps, same machine: plain 11.25 s, GLM substeps=1 11.59 s, GLM
substeps=4 **12.68 s**. That is **+12.7%** wall clock for a 15x divergence
reduction. Cleaning is two passes over 16,384 cells; the MUSCL flux is far
more expensive, so the ratio is favourable.

## A segfault found on the way

`mk_divb_cell` was not marked float-returning across the call boundary, so any
caller doing *arithmetic* on its result got a tagged int and crashed instantly:
`show_float (mk_divb_cell s i)` printed fine, `d * d` segfaulted. Comparison
survived the confusion, which is exactly why `mk_max_div_b` (which only ever
compares) worked for months while the first caller to square the result died.
Fixed at the source with a `+ 0.0` coercion so every future caller is safe
rather than each having to remember.

## What this does NOT claim

- Not a constrained-transport scheme. GLM controls divergence; it does not make
  the discretisation divergence-free. LF's 5.7e-15 comes from an accident of its
  flux structure and remains far cleaner in absolute terms.
- Not yet under the beacon. This is a new function; the beacon's Lax-Friedrichs
  path is untouched, and `t187` still pins plain MUSCL's dirtiness so nothing
  can be swapped by accident. Putting a second-order path under a live public
  surface is a separate decision with its own evidence bar.
