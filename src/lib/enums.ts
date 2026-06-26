// Shared enum-like constants. Kept OUT of "use server" files, which may only
// export async functions. Imported by both Server Actions and client components.

export const PERSON_ROLES = [
  "STUDENT", "COLLABORATOR", "COAUTHOR", "FACULTY", "COMMITTEE", "ADVISOR", "OTHER",
] as const;

export const PROJECT_STATUSES = [
  "IDEA", "ACTIVE", "PAUSED", "DONE", "DROPPED",
] as const;

export const TASK_STATUSES = ["TODO", "DOING", "DONE", "BLOCKED"] as const;

export const EVENT_TYPES = [
  "DEADLINE", "MEETING", "CLASS", "TRAVEL",
  "CONFERENCE", "REVIEW", "FOCUS", "OTHER",
] as const;

export const PAPER_STATUSES = [
  "IN_PREP", "SUBMITTED", "UNDER_REVIEW", "MAJOR_REV",
  "ACCEPTED", "PUBLISHED", "REJECTED",
] as const;

export const PROPOSAL_STATUSES = [
  "DRAFTING", "SUBMITTED", "UNDER_REVIEW", "AWARDED", "DECLINED",
] as const;

export const PROPOSAL_ROLES = ["PI", "CO_PI", "SENIOR_PERSONNEL"] as const;

export const APIKEY_STATUSES = ["ACTIVE", "REVOKED", "EXPIRED"] as const;

export const EXPENSE_STATUSES = ["PLANNED", "SUBMITTED", "REIMBURSED"] as const;

export const EXPENSE_CATEGORIES = [
  "AIRFARE", "LODGING", "MEALS", "REGISTRATION",
  "SUPPLIES", "SOFTWARE", "PUBLICATION", "OTHER",
] as const;

export const SUBSCRIPTION_CYCLES = ["MONTHLY", "QUARTERLY", "ANNUAL", "ONE_TIME"] as const;

export const TRIP_PURPOSES = ["CONFERENCE", "VISIT", "FIELDWORK", "OTHER"] as const;

export const DEADLINE_KINDS = [
  "CONF_ABSTRACT", "CONF_FULL", "JOURNAL", "REVIEW", "REBUTTAL", "CAMERA_READY",
] as const;
