# Post-Synthesis Leakage Power Minimization in Synopsys' PrimeTime

Post-Synthesis leakage power minimization procedure for Synopsys' PrimeTime, submitted to the low-power contest of the *'Synthesis and Optimization of Digital Systems'* course at PoliTO.

## Introduction

The power consumption of a CMOS digital circuit results from static and dynamic contributions. The dynamic power is dissipated when the circuit is active, that is, whenever transitions occur on a net due to input stimuli, and is further divided into switching and internal power:
- The switching power is associated with the charging and discharging of cells' capacitive loads, which include net and gate capacitances.
- The internal power is dissipated within the cell boundaries, not only by charging and discharging capacitances internal to the cell, but also when both pull-up and pull-down networks happen to conduct mid-commutation.

Conversely, the static power is dissipated when the circuit is inactive and arises from transistor non-idealities, primarily the reverse pn-junction current, the thin-oxide gate current, and the sub-threshold current; accordingly, it is also known as leakage power.  

Considering that for deep submicron technologies leakage power is approaching dynamic power, its minimization has been investigated at different levels of the VLSI design flow. While dealing with non-idealities typically pertains to transistor engineering done by the silicon vendor, the exponential dependence of the sub-threshold current on the transistor's sub-threshold voltage (V<sub>t</sub>) makes V<sub>t</sub>-sizing an effective optimization technique. Silicon vendors offer technologies where gates are available in two or more threshold voltage groups, each with different trade-offs of timing and leakage characteristics; it is then up to CAD tool vendors to implement algorithms that leverage these libraries to meet timing and power requirements.

## The Contest

Given a gate-level netlist synthesized with cells at the lowest V<sub>t</sub> option, the problem is to implement a procedure to run in Synopsys' PrimeTime to perform multi-V<sub>t</sub> cell assignment, such that:
- The leakage power is minimized.
- The worst slack is not negative.
- The cells retain their footprint.
- The optimization lasts no longer than 3 minutes.

The design kit comprises a technology library, the ST CMOS 65 nm in nominal conditions, with 3 V<sub>t</sub> options, LVT, SVT, and HVT,  and state-dependent cell leakage power characterization data. The effectiveness of the optimization is measured on ISCAS85 benchmark circuits, the c1908 and c5315, in terms of leakage power saving:
```math
    S = \frac{P_\text{lkg, initial}-P_\text{lkg, final}}{P_\text{lkg, initial}}
```
The thresholds to meet are the following:

| **Benchmark**| **Clock Period (ns)**| **S Threshold** |
|--------------|----------------------|-----------------|
| c1908        | 2.0                  | > 85%           |
| c1908        | 1.5                  | > 55%           |
| c1908        | 1.0                  | > 15%           |
| c5315        | 2.0                  | > 90%           |
| c5315        | 1.5                  | > 70%           |
| c5315        | 1.0                  | > 25%           |

## The Proposed Solution

V<sub>t</sub> sizing is an inherently discrete optimization problem, which is proved to be NP-hard; finding an optimal solution would be computationally prohibitive even for modest benchmark designs. Hence, I searched the literature for heuristics known to achieve good results under timing constraints. The solution strategy proposed in [1] revolves around a cost function that is globally aware of the entire circuit. The ideal cell to select for a V<sub>t</sub> increment is one that yields the highest leakage saving, while also consuming the least amount of total available slack:
```math
    \text{cost} = \frac{\text{worst slack reduction}}{\text{leakage saving}}
```
Ignoring the timing recovery through cell upsizing proposed by the authors, which would violate contest rules, their V<sub>t</sub> selection algorithm is arranged as a greedy optimization. First, cells are ranked according to the cost function above, where the worst slack reduction is computed by trial swapping one cell at a time to the next higher V<sub>t</sub>. Those cells for which this operation doesn't lead to a timing violation are *swappable candidates* to be processed in the order of least cost: each cell is swapped again to the higher V<sub>t</sub> option and the change is accepted if it doesn't cause a timing violation. Finally, the ranking operation is repeated and the loop continues so long as it is possible to identify swappable candidates.  

### Implementation Details

Preliminary implementations of this heuristic achieved high quality results, satisfying all contest target thresholds, but where violating the runtime constraint. The submitted solution is optimized for speed, with hand crafted solutions, rather than relying on ECO predictions through `estimate_eco`:

1. Prior to any optimization, `initLeakagePowerLut` analyzes each cell in the design not already at the highest V<sub>t</sub> option. It compiles in a dictionary the leakage power saving that would result from any subsequent V<sub>t</sub> increment, say from LVT to SVT and from SVT to HVT for a cell originally at LVT.
This operation has a crucial impact on performance. Every time a cell is swapped to a higher V<sub>t</sub> alternative with the `size_cell` command, leakage power annotations are invalidated and accessing any leakage power attribute triggers an expensive power update, with full switching activity propagation. As a consequence, `initLeakagePowerLut` is devised to limit power updates to the number of available V<sub>t</sub> options.

2. The global cost function proposed in [1] is expensive to compute. In the worst case, the ranking operation involves trial swapping each design cell to the next higher V<sub>t</sub>, one at a time. Not only this means resizing each cell twice, but the computation of the worst slack reduction triggers an incremental timing update for each "what if" scenario. The issue is mitigated by executing `localOptimization {select_pct derate_pct}`, a faster optimization loop that ranks design cells with a cost function that rewards large slack availability in the worst timing path through the cell, rather than a global slack metric. The arguments  control the swapping speed: the former sets the percentage of cells not already at the highest V<sub>t</sub> option to wholesale swap. Should this cause a timing violation, the latter argument dictates the percentage of cells from the previous attempt to retry swapping.

3. Ranking operations implicitly trigger timing updates when necessary. However, it seems that these timing computations are less accurate and could result in exiting the optimization loop with a negative slack. For this reason, when V<sub>t</sub> changes are finalized, the worst slack evaluation is performed only after explicitly triggering a full timing update.

4. `globalOptimization {start_time_ms max_runtime_ms}` based on [1] might still exceed the contest's runtime limit. To address this, the optimization procedure is made "time aware". Each iteration is timed in milliseconds since the epoch, and an exponential moving average helps predict the duration of the next iteration. Should it complete after `start_time_ms` + `max_runtime_ms`, the optimization stops early.

5. Technology-specific details are collected in the `::STcmos65` namespace. In particular, the dictionary `VT_LUT` is accessed through the helper procedure `getVtAlternative` to generate library cells' full names for performing V<sub>t</sub> swaps.

### Results

Runs with various server workloads showed that the proposed solution meets the contest's thresholds. The table below summarizes the typical results in the proposed benchmarks, comparing them with Synopsys' leakage power minimization ECO flow. This is achieved by invoking `fix_eco_power -pattern_priority {HS65_LH HS65_LS HS65_LL}`. The missing data in the highest effort scenarios is due to unexpected terminations of the flow with timing violations, despite having attempted to enforce a zero setup margin configuration.

| **Benchmark**| **Clock Period (ns)**| **S Threshold**| `fix_eco_power` **S / Time (s)**| `multiVth` **S / Time (s)**|
|--------------|----------------------|----------------|---------------------------------|----------------------------|
| c1908        | 2.0                  | > 85%          | 87.591 % / 3.603                | 95.483 % / 23.181          |
| c1908        | 1.5                  | > 55%          | slack: -0.006782                | 65.964 % / 27.731          |
| c1908        | 1.0                  | > 15%          | slack: -0.000680                | 16.674 % / 40.222          |
| c5315        | 2.0                  | > 90%          | 74.568 % / 8.114                | 97.730 % / 67.213          |
| c5315        | 1.5                  | > 70%          | 58.652 % / 8.348                | 82.333 % / 125.87          |
| c5315        | 1.0                  | > 25%          | slack: -0.003441                | 25.416 % / 117.641         |

## References

[1] M. Rahman and C. Sechen, "Post-synthesis leakage power minimization," 2012 Design, Automation & Test in Europe Conference & Exhibition (DATE), Dresden, Germany, 2012, pp. 99-104, doi: [10.1109/DATE.2012.6176440](https://doi.org/10.1109/DATE.2012.6176440).  
[2] Synopsys, Inc., "PrimeTime User Guide"  
[3] Synopsys, Inc., "Power Compiler User Guide"
