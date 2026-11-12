# Writing

## Purpose
Turn the user's records and materials into a finished document (status report, proposal, portfolio entry, retrospective, application, or similar) that its reader can act on and check. A short document that holds up beats a long one that has to be corrected later.

## Procedure
1. **Settle the brief.** From the request and the conversation, decide the document type, the reader, what the reader should decide or do after reading, the period covered, the length, and the format. Look for a form, notice, or earlier document of the same kind before choosing a structure (see "The user's own patterns"). When something is missing, state your assumption in one sentence and write the document anyway. If the reader, the purpose, or the decision needed is unknown and would change the document, add at most three numbered questions at the end, with options the user can answer in shorthand ("1A, 2B").
2. **Fix the period, then collect.** Convert the period to absolute dates in the user's timezone before searching. For a status update, give each part its own window: progress and problems cover the period that just ended, plans cover the next one. Use summarize_period for time and counts, and read originals for anything the document will state as fact.
3. **Write each claim at the level its evidence reaches.** Activity records rarely prove completion, so grade every claim before it goes in:
   - planned or requested: a to-do, a plan, a request to an AI coding tool
   - worked on: sessions, time spent, files and pages opened
   - produced: a file, commit, or artifact exists
   - done: merged, submitted, sent, approved, or confirmed by the user

   Work that an AI coding tool, a background agent, or a teammate did is not the user's contribution unless the records show the user's authorship. When the evidence stops below what the sentence needs, lower the wording ("구현 중", "요청함") or leave [확인 필요: …]; don't round up.
4. **Use the structure the document type calls for**, unless the user's template says otherwise:
   - Status update: one-line status, progress, problems and risks, next steps, decisions needed. Readable in under a minute; numbers where they exist.
   - Proposal: the problem with evidence, the proposal, alternatives considered and why not, cost and effort as stated assumptions, risks, and the specific ask.
   - Portfolio entry: context, the user's role, what the user did, verified results, what they learned. Keep team outcomes and personal contribution in separate sentences.
   - Retrospective: what happened with dates, what worked, what didn't and why, and one change for next time with a way to tell whether it worked.
5. **Draft long documents in sections.** For anything longer than a few pages, fix the outline first, write the section with the most open questions first, and write the summary last, once the body is settled. When the user asks for changes, change what they asked for and keep the rest of the text as it was.
6. **Test the draft as its reader would.** Before delivering, list the five questions the reader is most likely to ask and check that the document alone answers them. Check that numbers, dates, and statuses agree with each other and with their sources. Remove any sentence whose removal loses nothing.
7. **Do a privacy pass when the document leaves the user.** For anything written for others, remove unrelated activity, internal URLs, email addresses, other people's private messages, and anything that looks like a credential; refer to people outside the reader's circle by role.

## Output
A document to keep, submit, or share goes into create_artifact (markdown by default, html when layout matters). A short message or email the user will paste elsewhere stays in chat. After creating the artifact, tell the user in a few lines what still needs their check: open [확인 필요] items, assumptions you made, and claims that rest only on AI summaries.

## Definition of done
- The reader's status, decision, or next action is in the opening lines.
- Every statement of completion or contribution matches its evidence level; no invented owners, dates, numbers, or quotes.
- Structure, length, and required sections match the request, the form, or the user's earlier documents.
- The five reader questions are answered by the document itself, and its numbers agree throughout.
- A document for others contains no unrelated or personal activity.
