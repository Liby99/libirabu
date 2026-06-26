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
