# File              : multiVth.tcl
# Author            : Fabio Scatozza <s315216@studenti.polito.it>
# Date              : 22.06.2024

## @brief Collects technology library specific definitions

namespace eval STcmos65 {

  ## @brief Alias for Vt groups library cell attributes

  variable VT_ALIAS_ENUM {
    {LVT}
    {SVT}
    {HVT}
  }

  ##
  # @brief Lookup dictionary for Vt swaps
  #
  # For a library name and increment step, it stores:
  #   - The library name to swap to
  #   - The library cells' base_name prefix to substitute
  #   - The replacement for the library cells' base_name prefix

  variable VT_LUT {
    CORE65LPLVT {
      1 {
        libto   {CORE65LPSVT}
        xfrom   {HS65_LL}
        xto     {HS65_LS}
      }
    }
    CORE65LPSVT {
      -1 {
        libto   {CORE65LPLVT}
        xfrom   {HS65_LS}
        xto     {HS65_LL}
      }
      1 {
        libto   {CORE65LPHVT}
        xfrom   {HS65_LS}
        xto     {HS65_LH}
      }
    }
    CORE65LPHVT {
      -1 {
        libto   {CORE65LPSVT}
        xfrom   {HS65_LH}
        xto     {HS65_LS}
      }
    }
  }

  ##
  # @brief Lookup dictionary for cells' leakage power saving
  #
  # For a cell's base_name and ref_name, it stores the leakage power reduction
  # that would result from swapping the cell with its higher Vt alternative.
  # It is initialized by initLeakagePowerLut()

  variable LKG_LUT
}

##
# @brief Returns the smaller in a list of values
# @param v The list of values
# @return The smaller value in the list
#
# @note Faster implementation of ::tcl::mathfunc::min

proc lmin {v} {
  set vv_ [lindex $v 0]
  foreach vv $v {
    if {$vv < $vv_} {
      set vv_ $vv
    }
  }
  return $vv_
}

##
# @brief Retrieves the library cell alternative with higher/lower Vt
#
# Operation is assumed to be valid.
#
# @param lib_from The library the cell belongs to
# @param name The cell's ref_name, corresponding to a base_name in lib_from
# @param step Whether to increment/decrement Vt, respectively `-1` or `1` (default)
# @return lib_to/ref_name_to for swapping with the library cell alternative

proc getVtAlternative {lib_from ref_name {step 1}} {
  variable ::STcmos65::VT_LUT

  set lib_to [dict get $VT_LUT $lib_from $step libto]
  regsub [dict get $VT_LUT $lib_from $step xfrom] $ref_name [dict get $VT_LUT $lib_from $step xto] ref_name_to
  return $lib_to/$ref_name_to
}

##
# @brief Initializes the leakage power saving lookup dictionary
#
# In general, each design cell is mapped to a library cell: if the cell
# is not already at the highest Vt option, the library cell is to be analyzed
# to compute the leakage power saving that would result from swapping it
# to the higher Vt alternative.
#
#   1) Multiple design cells can be mapped to the same library cell.
#   In general, their leakage power is different, hence the lookup dictionary
#   requires both base_name and ref_name as keys.
#
#   2) For a library cell under analysis, computing the leakage power
#   saving when switching to the higher Vt alternative requires:
#     - saving the leakage power of any one of the design cells mapped to it
#     - swapping this design cell to the higher Vt alternative
#     - saving the leakage power of this modified design cell
#   This last operation triggers a computationally expensive power update,
#   thus should be executed only once all swaps have already been committed:
#   this implementation triggers as many updates as the possible Vt options.
#
# @param args The option `-fast` is devised to comply with contest runtime
# constraints. It restricts the analysis to all cells at the lowest Vt option.

proc initLeakagePowerLut {args} {
  variable ::STcmos65::VT_ALIAS_ENUM
  variable ::STcmos65::LKG_LUT

  # depending on the option, select all cells not already at highest Vt or all those at lowest Vt
  set filter_expr "lib_cell.threshold_voltage_group [expr {$args == {-fast} ? "== [lindex $VT_ALIAS_ENUM 0]" : "!= [lindex $VT_ALIAS_ENUM end]" }]"
  set swappable_cells [get_cells -quiet -filter $filter_expr]
  set full_names [get_attribute $swappable_cells lib_cell.full_name]

  # Cells to modify are mapped to their initial lib_cell's full_name
  set undo_list {}
  set idx 0
  foreach_in_collection cell $swappable_cells {
    lappend undo_list $cell [lindex $full_names $idx]
    incr idx
  }

  while {[sizeof_collection $swappable_cells] > 0} {
    set full_name_pairs [split $full_names {/ }]
    set base_names [get_attribute $swappable_cells base_name]

    # the leakage power is retrieved before swapping any cell for the iteration
    set leakage_powers [get_attribute $swappable_cells leakage_power]

    set idx 0
    foreach {lib_name ref_name} $full_name_pairs {
      size_cell [index_collection $swappable_cells $idx] [getVtAlternative $lib_name $ref_name]
      incr idx
    }

    # single implicit power update after all cells are swapped
    foreach base_name $base_names {- ref_name} $full_name_pairs lkg_from $leakage_powers lkg_to [get_attribute $swappable_cells leakage_power] {
      dict set LKG_LUT $base_name $ref_name [expr {$lkg_from-$lkg_to}]
    }

    # look for cells that are still swappable
    if {$args == {-fast}} {
      break
    }
    set swappable_cells [filter_collection $swappable_cells[set swappable_cells {}] $filter_expr]
    set full_names [get_attribute $swappable_cells lib_cell.full_name]
  }

  # final unswap based on the initial mapping
  foreach {cell full_name} $undo_list {
    size_cell $cell $full_name
  }
}

##
# @brief Generates a list of candidate cells to swap to higher Vt
#
# The assumption is that the design is not violating timing constraints.
# All cells not already at highest Vt are sorted by increasing cost, where
# the cost function rewards:
#
#   - Large leakage power saving
#     (according to the leakage power saving lookup dictionary)
#   - Large slack availability
#
# @note The cell's slack is computed as the minimum max_slack of its pins,
# which is faster but equivalent to
#
#   `[get_attribute [get_timing_paths -through $cell] slack]`
#
# provided that `timing_save_pin_arrival_and_slack` is set to true.
#
# @return {cost lib_name ref_name base_name cell}* sorted by increasing cost

proc rankCellsLocalSlackLkg {} {
  variable ::STcmos65::VT_ALIAS_ENUM
  variable ::STcmos65::LKG_LUT

  # candidate cells are all those not already at highest Vt
  set swappable_cells [get_cells -quiet -filter "lib_cell.threshold_voltage_group != [lindex $VT_ALIAS_ENUM end]"]
  set base_names [get_attribute $swappable_cells base_name]
  set full_names [get_attribute $swappable_cells lib_cell.full_name]

  set idx 0
  set ranking {}

  foreach_in_collection cell $swappable_cells {
    set base_name [lindex $base_names $idx]
    lassign [split [lindex $full_names $idx] /] lib_name ref_name

    set slack [lmin [get_attribute [get_pins -of_objects $cell] max_slack]]
    set lkg_saving [dict get $LKG_LUT $base_name $ref_name]
    set cost [expr {1/($slack*$lkg_saving)}]

    lappend ranking $cost $lib_name $ref_name $base_name $cell
    incr idx
  }

  return [lsort -real -stride 5 $ranking]
}

##
# @brief Generates a list of candidate cells to swap to higher Vt
#
# Compared to rankCellsLocalSlackLkg(), it's specifically optimized for speed.
# The cell under analysis are all those at the lowest Vt option, for which
# the cost is computed accounting only for slack availability.
#
# @return {cost lib_name ref_name base_name cell}* sorted by increasing cost

proc rankCellsLocalSlackFast {} {
  variable ::STcmos65::VT_ALIAS_ENUM

  # restrict candidates to all cells at lowest Vt
  set swappable_cells [get_cells -quiet -filter "lib_cell.threshold_voltage_group == [lindex $VT_ALIAS_ENUM 0]"]
  set full_names [get_attribute $swappable_cells lib_cell.full_name]

  set idx 0
  set ranking {}

  foreach_in_collection cell $swappable_cells {
    lassign [split [lindex $full_names $idx] /] lib_name ref_name

    set slack [lmin [get_attribute [get_pins -of_objects $cell] max_slack]]
    lappend ranking $slack $lib_name $ref_name {} $cell
    incr idx
  }

  # the cost function rewards high slack availability: minimum cost <=> highest slack
  return [lsort -real -decreasing -stride 5 $ranking]
}

##
# @brief Generates a list of candidate cells to swap to higher Vt
#
# The assumption is that the design is not violating timing constraints.
# All cells not already at highest Vt are sorted by increasing cost, where
# the cost function rewards:
#
#   - Large leakage power saving
#     (according to the leakage power saving lookup dictionary)
#   - Small critical path's slack reduction
#
# Computing the critical path's slack reduction requires a "what if" analysis,
# in which the candidate cell is replaced with its higher Vt alternative: this
# amounts to 2 swaps and an implicit timing update per cell.
# If the swap results in a timing violation, the cost is taken to be infinite
# and the cell is filtered out of the ranking list.
#
# @see M. Rahman and C. Sechen, "Post-synthesis leakage power minimization,"
# 2012 Design, Automation & Test in Europe Conference & Exhibition (DATE),
# Dresden, Germany, 2012, pp. 99-104, doi: 10.1109/DATE.2012.6176440.
#
# @param args The option `-fast` is devised to comply with contest runtime
# constraints. It restricts the analysis to all cells at the lowest Vt option.
# @return {cost lib_name ref_name base_name cell}* sorted by increasing cost

proc rankCellsGlobal {args} {
  variable ::STcmos65::VT_ALIAS_ENUM
  variable ::STcmos65::LKG_LUT

  # depending on the option, select all cells not already at highest Vt or all those at lowest Vt
  set filter_expr "lib_cell.threshold_voltage_group [expr {$args == {-fast} ? "== [lindex $VT_ALIAS_ENUM 0]" : "!= [lindex $VT_ALIAS_ENUM end]" }]"
  set swappable_cells [get_cells -quiet -filter $filter_expr]

  set base_names [get_attribute $swappable_cells base_name]
  set full_names [get_attribute $swappable_cells lib_cell.full_name]

  set idx 0
  set ranking {}
  set global_slack [get_attribute [get_timing_paths] slack]

  foreach_in_collection cell $swappable_cells {
    set base_name [lindex $base_names $idx]
    lassign [split [lindex $full_names $idx] /] lib_name ref_name

    # total leakage power reduction is retrieved from the lookup dictionary
    set lkg_saving [dict get $LKG_LUT $base_name $ref_name]

    # total slack reduction is computed on the fly
    size_cell $cell [getVtAlternative $lib_name $ref_name]
    set new_global_slack [get_attribute [get_timing_paths] slack]
    size_cell $cell $lib_name/$ref_name

    if {$new_global_slack > 0} {
      set cost [expr {($global_slack-$new_global_slack)/$lkg_saving}]
      lappend ranking $cost $lib_name $ref_name $base_name $cell
    }
    incr idx
  }

  return [lsort -real -stride 5 $ranking]
}

##
# @brief Swaps cells to the higher Vt alternative
#
# @param ranking {cost lib_name ref_name base_name cell}* generated by rankCells()
# @return {cell full_name_to}* for reverting the swap

proc swapCells {ranking} {
  set undo_list {}
  foreach {- lib_name ref_name - cell} $ranking {
    size_cell $cell [getVtAlternative $lib_name $ref_name]
    lappend undo_list $cell $lib_name/$ref_name
  }
  return $undo_list
}

##
# @brief Performs the Vt assignment to locally optimize leakage power
#
# The local nature of the optimization comes from the ranking functions,
# which don't account for the effects of the swap on the whole design.
#
# @param ranking_function `rankCellsLocalSlackLkg` or `rankCellsLocalSlackFast`
# @param select_pct The percentage of candidates cells to wholesale swap
# @param derate_pct Once the wholesale swap of the candidates has failed,
# the percentage of those cells to re-attempt swapping
#
# @note After the swap, an incremental timing update is not sufficitently
# accurate to ensure the optimization loop ends with the design compliant
# with timing constraints.

proc localOptimization {ranking_function select_pct derate_pct} {

  # generate ranking
  set ranking [$ranking_function]
  set n_swappable [expr {[llength $ranking]/5}]
  set n_toswap [expr {int(ceil($n_swappable*$select_pct))}]
  dputs "(localOptimization <$ranking_function>) Swapping $n_toswap ..."

  # if there are candidates to swap
  while {$n_toswap > 0} {

    # swap them
    set undo_list [swapCells [lrange $ranking 0 [expr {$n_toswap*5-1}]]]
    update_timing -full

    # and check for timing violations
    if {[get_attribute [get_timing_paths] slack] >= 0} {

      # prepare next swap
      # stop condition: n_swappable = 0
      set ranking [$ranking_function]
      set n_swappable [expr {[llength $ranking]/5}]
      set n_toswap [expr {int(ceil($n_swappable*$select_pct))}]
      dputs "(localOptimization <$ranking_function>) Swapping $n_toswap ..."

    } else {

      # if there is a violation, undo the swap
      foreach {cell full_name_to} $undo_list {
        size_cell $cell $full_name_to
      }

      # and attempt a finer selection
      # stop condition: n_toswap --> 0
      set n_toswap [expr {int(floor($n_toswap*$derate_pct))}]
      dputs "(localOptimization <$ranking_function>) Violation detected. Attempting with $n_toswap ..."
    }
  }

}

##
# @brief Performs the Vt assignment to globally optimize leakage power
#
# The global nature of the optimization comes from the ranking function,
# which performs "what if" analyses to account for the effects of the swaps
# on the whole design.
#
# Given the contest runtime constraints, the optimization loop is time-aware.
# The duration of the iterations is tracked with an exponential moving average,
# to predict whether the subsequent iteration would complete in time.
#
# @param args Syntax: ?-fast? start_time_ms max_time_ms select_n
#
#   -fast If present, the option is passed to the ranking function to restrict
# the analysis to all cells at the lowest Vt option. In addition, it disables
# checking for locksteps in which the same cell is ranked as eligible for a swap
# (because of the lower accuracy of incremental timing updates), but then it
# generates a timing violation after applying the swap.
#
#   select_n The number of cells to wholesale swap (>= 1).
#
#   start_time_ms The time (count of milliseconds since epoch) when the
# optimization started.
#
#   max_time_ms The maximum runtime in milliseconds for the optimization.
#
# @note After the swap, an incremental timing update is not sufficitently
# accurate to ensure the optimization loop ends with the design compliant
# with timing constraints.

proc globalOptimization {args} {
  if {[llength $args] == 4} {
    lassign $args opt select_n start_time_ms max_time_ms
  } else {
    lassign $args select_n start_time_ms max_time_ms opt
  }

  # exponential moving average initialization
  set dt {}
  set alpha 0.3

  # generate ranking
  set t0 [clock milliseconds]
  set ranking [rankCellsGlobal $opt]
  set n_swappable [expr {[llength $ranking]/5}]

  # as long as there are candidates
  while {$n_swappable > 0} {
    dputs "(globalOptimization) $n_swappable candidates found ..."

    # swap as many as possible, selecting select_n at a time in the first attempt
    set swap_size $select_n
    set n 0
    while {1} {

      set violation 0
      for {} {$n < $n_swappable} {incr n $swap_size} {
        dputs "(globalOptimization) Swapping [expr {min($n+$swap_size, $n_swappable+1)-$n}] at a time, from $n ([expr {$n*5}])..."
        set undo_list [swapCells [lrange $ranking [expr {$n*5}] [expr {min($n+$swap_size, $n_swappable+1)*5-1}]]]
        update_timing -full

        # if there is a violation, unswap the last batch
        if {[get_attribute [get_timing_paths] slack] < 0} {
          dputs "(globalOptimization) Unswapping [expr {[llength $undo_list]/2}] ..."
          foreach {cell full_name_to} $undo_list {
            size_cell $cell $full_name_to
          }
          # and try with a smaller swap_size
          incr violation
          incr swap_size -1
          break
        }
      }

      # until all is done with no violation, or there is no new swap_size to try
      if {!$violation || $swap_size == 0} {dputs "(globalOptimization) Done: n = $n ..."; break}
      dputs "(globalOptimization) Restarting from $n ([expr {$n*5}]), $swap_size at a time ..."
    }

    # update the average iteration duration and check if there's time for one more
    set t1 [clock milliseconds]
    set dt [expr {$dt == {} ? $t1-$t0 : $alpha*($t1-$t0)+(1-$alpha)*$dt}]
    dputs "(globalOptimization) @ $t1: dt = $dt"
    if {$t1 + $dt >= $start_time_ms + $max_time_ms} {
      dputs "(globalOptimization) Time is up ..."
      break
    }

    # if there is time, prepare the new iteration
    set t0 [clock milliseconds]
    set prev_ranking $ranking
    set ranking [rankCellsGlobal $opt]
    set n_swappable [expr {[llength $ranking]/5}]

    # if not in fast mode, check that the candidate cells are different to prevent locksteps
    if {$opt != {-fast} && ([llength $ranking] == [llength $prev_ranking]) &&
    ([lmap {- - - base_name -} $ranking {set base_name}] == [lmap {- - - base_name -} $prev_ranking {set base_name}])} {
      dputs "(globalOptimization) Lockstep. Aborting ..."
      break
    }
  }

}


##
# @brief The full optimization recipe
#
# The parameters of the optimization commands result from tests
# on the contest benchmark circuits (c1908, c5315)

proc multiVth {} {

  set start_time_ms [clock milliseconds]
  set n_cells [sizeof_collection [get_cells]]

  if {$n_cells > 300 && [get_attribute [get_timing_paths] slack] < .001} {
    initLeakagePowerLut -fast
    localOptimization rankCellsLocalSlackFast [expr {68.0/$n_cells}] 0
    globalOptimization -fast 4 $start_time_ms 180000
  } else {
    initLeakagePowerLut
    localOptimization rankCellsLocalSlackLkg 1 .95
    globalOptimization 4 $start_time_ms 180000
  }

}

##
# @brief DEBUG SUPPORT
#
# Select one to enable/disable debug messages

#proc dputs args {puts stderr $args}
proc dputs args {}
