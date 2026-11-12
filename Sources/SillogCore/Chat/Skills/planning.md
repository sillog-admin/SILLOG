# Planning

## Purpose
Turn a goal into a plan the user can start on today: deliverables with checkable done criteria, an order that respects dependencies and real capacity, and a clear list of the decisions only the user can make. Finding facts is your job; making scope, cost, and design decisions is the user's.

## Procedure
1. **Learn what is already known.** Before asking anything, look up the related tasks, recent sessions, open to-dos (LaterItems), earlier plans, and any brief or notice in the records and library. Then make the plan in this reply. Fill gaps with stated assumptions, and put at most three numbered questions at the end, each with options and your recommended default, so the user can reply "1A, 2 기본값". Ask before planning only when the goal itself is unclear.
2. **Establish the current state.** Sort the work into done (with evidence), in progress, requested only, and not started. A plan, a request, or an open page never counts as done.
3. **Define the target.** Write the goal, how success will be measured, what is out of scope, and what would make the result a failure even if every task were finished. List the constraints: deadline, hours available, people, budget, and approvals from others.
4. **Show real choices.** When scope, order, or approach can reasonably go more than one way, lay out two or three options with their trade-offs and recommend one. Record the choice as a decision for the user instead of settling it silently.
5. **Break the work down.** Go from deliverables to tasks. Each task is one action with a result someone can check, its dependencies, and the materials it needs. For a large plan, settle the milestones first and break down only the first milestone in detail; offer to detail the rest once the user agrees with the shape.
6. **Estimate from history.** Base estimates on the actual time similar past tasks took (summarize_period, or a task's active time), give a range, and state the assumptions. Label every figure 확정 or 추정. Name an owner or a date only when a source does; otherwise write 미정.
7. **Check the plan against capacity.** Add up the estimates and compare them with the time available before the deadline. If the plan doesn't fit, say so plainly and give the options (cut scope, move the date, add help) with what each costs.
8. **Name the risks.** List the top three risks, each with an early warning sign and a response.
9. **When updating a plan,** compare it with the previous version: done, slipped, added, and dropped, each with its evidence. Don't guess why something changed.
10. **Review before delivering.** Every requirement maps to at least one task; no step is a placeholder ("TBD", "세부 사항 처리"); names stay consistent; and the plan is no bigger than the request.

## Output
Goal and done criteria, current state, the task list (a table with task, done check, depends on, estimate, and owner or date with its 확정/추정/미정 status), decisions needed, risks, and the first action to take today. A multi-week plan goes into a markdown artifact; a roadmap or checklist meant for a spreadsheet goes into csv. If the user wants regular check-ins, mention that a scheduled task can do them, and propose one only when they ask.

## Definition of done
- Each task produces a deliverable with a check, rather than describing activity.
- Dependencies, capacity, and the deadline are consistent, or the conflict is stated with options.
- Owners, dates, and costs are marked 확정, 추정, or 미정; nothing undecided is written as decided.
- The decisions the user must make and the first action are clear.
