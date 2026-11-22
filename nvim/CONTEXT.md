# Neovim configuration

The language used when discussing this configuration's own features. Terms are added as they are settled.

## Language

### JSONL viewing

**Session transcript**:
A JSONL file an agent harness writes for one session: the conversation, the tool traffic and the harness's own bookkeeping, as one **Record** per event.
_Avoid_: Conversation history, chat log, session file

**Subagent transcript**:
The **Session transcript** of an agent that another session started to do part of its work. It names the session that started it, and its **Prompts** were written by that session's agent, not by the user.
_Avoid_: Child session, nested transcript, task log

**Record**:
One line of a JSONL file, holding one JSON value. A **Session transcript** has thousands.
_Avoid_: Line, row, entry

**Transcript format**:
The shape the agent harness gives the **Records** of a **Session transcript**. It has a version, and a file is a **Session transcript** only if it declares a version that is understood.
_Avoid_: Schema, session format, log format

**Conversation**:
What a **Session transcript** says: its **Turns**, in order. The **Session transcript** is the file, **Bookkeeping records** included; the conversation is the small part of it that is read.
_Avoid_: Chat, dialogue, history, thread

**Contribution**:
What one **Record** adds to the **Conversation**: the start of a **Turn**, text or **Steps** of a **Response**, the result of a **Step**, a **Notice**, a **Compaction**, a fact about the session such as its title, or nothing. It is stated in conversation terms, never in terms of the **Transcript format**.
_Avoid_: Event, fragment, entry, description

**Transcript view**:
The whole conversation of one **Session transcript** as a single continuous, read-only text: what was said and the tool traffic, in order. It exists only for a **Session transcript**.
_Avoid_: Rendered view, chat view, conversation buffer

**Record preview**:
One **Record** shown by itself as formatted JSON, beside the file it came from. It works on any JSONL file and is what a file that is not a **Session transcript** gets.
_Avoid_: Pretty view, JSON view, detail pane

**Turn**:
One exchange in a **Session transcript**: a **Prompt** and the **Response** to it. A turn spans many **Records**; the **Transcript view** is a sequence of turns.
_Avoid_: Exchange, round, message pair

**Prompt**:
What starts a **Turn**: text given to the assistant by the user or, in a **Subagent transcript**, by the agent that started it.
_Avoid_: User message, question, request

**Response**:
Everything the assistant produced in one **Turn**, in order: its thinking, its tool calls with their results, and its text.
_Avoid_: Assistant turn, reply, assistant message, output

**Step**:
One thing the assistant did in a **Response** other than speak: a thought, or a tool call together with its result. A **Response** is a sequence of steps and text.
_Avoid_: Action, tool use, operation, event

**Notice**:
Something the harness itself put into the conversation and showed the user, such as a background job's result or a message from another agent. It sits inside a **Turn** but belongs to neither the **Prompt** nor the **Response**.
_Avoid_: System message, injected message, custom message

**Compaction**:
A point in a **Conversation** where the harness replaced what the assistant remembers of the earlier **Turns** with a summary. The earlier **Turns** are still in the **Session transcript**.
_Avoid_: Summary, context reset, truncation

**Bookkeeping record**:
A **Record** the harness keeps for itself and never shows. The **Transcript view** counts it and does not draw it.
_Avoid_: Metadata, internal record, noise

**Unrecognised record**:
A **Record**, or a piece of one, of a kind the reader does not know. The **Transcript view** always says so, by name; it is never silently left out.
_Avoid_: Unknown record, unsupported record, skipped record

**Transcript link**:
A line in the **Transcript view** that points at another **Session transcript**: from a **Step** to the **Subagent transcript** it started, or from a **Subagent transcript** back to the session that started it. Opening it goes to that transcript's view.
_Avoid_: Reference, jump, following a subagent

**Live transcript**:
A **Session transcript** whose session is still running, so **Records** are still being appended to it.
_Avoid_: Active session, open transcript

**Following**:
The **Transcript view** growing as its **Live transcript** grows. It happens only while the view is on screen.
_Avoid_: Tailing, watching, live reload, auto-refresh

## Flagged ambiguities

- "Line" was used for both a **Record** and a line of text inside a message. A **Record** is always called a record; "line" means a line of text as shown on screen.
- "Assistant turn" was used for the assistant's half of a **Turn**. A **Turn** includes the **Prompt**; the assistant's half is the **Response**.
- "Follow" was used for going from a session to a **Subagent transcript** and back. **Following** means only the view growing with a **Live transcript**; going to another transcript is opening a **Transcript link**.

## Example dialogue

> **Dev:** How long is this session transcript?
> **Expert:** About 2,300 records, but the conversation is 45 turns. Most records are bookkeeping, or the results of steps.
> **Dev:** So one record is not one turn.
> **Expert:** No. A record makes a contribution: my prompt starts a turn, an assistant record adds text and steps to the response, a tool-result record finishes a step. A bookkeeping record contributes nothing and is only counted.
> **Dev:** And if the harness starts writing a kind of record we have never seen?
> **Expert:** Then it is an unrecognised record, and the transcript view says so where it happened. If the transcript format's version changes, the file is not treated as a session transcript at all and I get the record preview.
> **Dev:** This step started three subagents. Where is their work?
> **Expert:** In three subagent transcripts. The step has a transcript link to each, and each of them has one back.
> **Dev:** The session is still running. Will I see the next turn?
> **Expert:** It is a live transcript, so the view is following it while it is on screen.
