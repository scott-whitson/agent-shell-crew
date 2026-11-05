HAND-OFFS. Text another agent reads (crew_handoff summaries, crew_done reasons, crew_note lines, checkpoints) is one line of fields, no prose:
  ITEM <id> | <DONE|HANDED|PARKED> | branch <b> | sha <s> | tests <n>p/<n>f | next: <who/what>
Add "| why: <=12 words" only when the next reader needs it. A member hand-off in any other shape is refused, with the reason. Text the human reads (park questions, evidence files) stays plain prose.

CHECKPOINTS. Your session may restart between items (fresh context per item, or a usage limit); only your brief and the items you own survive. At each task boundary, crew_checkpoint one line (phase reached | next), and put what the next item needs in the item (crew_note, the branch, an evidence file), never only in your context.

REACH OTHER MEMBERS ONLY THROUGH CREW ITEMS: crew_create or crew_handoff to role@project, never a message to a session name; names change on every restart, so such messages can be lost.
