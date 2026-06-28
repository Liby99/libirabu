// The assistant's tool registry. P0 is read-only: screen state, calendar reads, web.
// Mutating tools (create/update/delete) + the auditor arrive in P1 (design §13).

import type { AssistantTool } from "../types";
import { calendarTools } from "./calendar";
import { webTools } from "./web";
import { memoryTools } from "./memory";

export const tools: AssistantTool[] = [...calendarTools, ...webTools, ...memoryTools];

export const toolByName = new Map(tools.map((t) => [t.def.name, t]));

export const toolDefs = tools.map((t) => t.def);
