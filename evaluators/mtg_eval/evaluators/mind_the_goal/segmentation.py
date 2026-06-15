"""Goal segmentation: group turns into goals based on LLM labels."""

from __future__ import annotations

from shared.models import Goal, TurnQuality, RCOFCode


def segment_goals(raw_turns: list[dict], turn_qualities: list[TurnQuality]) -> list[Goal]:
    """Segment turns into goals based on is_new_goal labels from LLM."""
    if not raw_turns:
        return []

    # Build quality lookup
    quality_map = {tq.turn_number: tq for tq in turn_qualities}

    goals = []
    current_turns = []
    goal_id = 0

    for rt in raw_turns:
        turn_num = rt.get("turn_number", 0)
        is_new = rt.get("is_new_goal", "yes").lower() == "yes"

        if is_new and current_turns:
            # Finalize previous goal
            goal_id += 1
            goals.append(_build_goal(goal_id, current_turns, quality_map))
            current_turns = []

        current_turns.append(turn_num)

    # Finalize last goal
    if current_turns:
        goal_id += 1
        goals.append(_build_goal(goal_id, current_turns, quality_map))

    return goals


def _build_goal(goal_id: int, turn_numbers: list[int], quality_map: dict[int, TurnQuality]) -> Goal:
    """Build a Goal from turn numbers and quality assessments."""
    # Strict: goal fails if ANY turn fails
    failed_turn = None
    rcof = None
    quality = "success"

    for tn in turn_numbers:
        tq = quality_map.get(tn)
        if tq and tq.quality == "failure":
            quality = "failure"
            if failed_turn is None:  # Earliest failed turn
                failed_turn = tn
                rcof = tq.rcof
            break  # RCOF = earliest failure

    return Goal(
        goal_id=goal_id,
        turns=turn_numbers,
        quality=quality,
        rcof=rcof,
        failed_turn=failed_turn,
    )
