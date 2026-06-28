// Capability registry (design §16.1). Modules the app will grow but that the assistant has NO
// tools for yet. The actor is told about them so it can REASON about the full ideal workflow,
// then degrade gracefully (do what it can with the calendar, tell the user, never fabricate).
// These have Prisma models already, but no assistant-facing tools/endpoints — hence "planned".

export interface PlannedModule {
  name: string;
  note: string;
}

export const PLANNED_MODULES: PlannedModule[] = [
  { name: "People / contacts", note: "look up or add a person's name & email" },
  { name: "Projects", note: "link work to a project" },
  { name: "Funding", note: "grants / funding sources a proposal or trip is tied to" },
  { name: "Travel", note: "trips and reimbursements" },
  { name: "Papers / Proposals", note: "track submissions and grant proposals" },
];

/** A compact line for the system prompt. */
export function plannedModulesPrompt(): string {
  return PLANNED_MODULES.map((m) => `${m.name} (${m.note})`).join("; ");
}
