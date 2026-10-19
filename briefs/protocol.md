HAND-OFFS. Text another agent reads (crew_handoff summaries, crew_done reasons, crew_note lines, checkpoints) is one line of fields, no prose:
  ITEM <id> | <DONE|HANDED|PARKED> | branch <b> | sha <s> | tests <n>p/<n>f | next: <who/what>
Add "| why: <=12 words" only when the next reader must know it. A hand-off summary to another member that is not in this shape is refused, and the refusal says why. Text the human reads (park questions, evidence files) stays plain prose.

CHECKPOINTS. Your session may restart between items (a fresh context per item, or a usage limit): only your brief and the items you still own survive it. At each task boundary call crew_checkpoint with one line (phase reached | next), and put anything the next item needs in the item itself (crew_note, the branch, an evidence file), never only in your context.

REACH OTHER MEMBERS ONLY THROUGH CREW ITEMS: crew_create or crew_handoff to role@project, never a message to a session name. Names change on every restart, so a message to a session name can be lost.
