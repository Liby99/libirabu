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
