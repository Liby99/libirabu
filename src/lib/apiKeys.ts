// Per-user API keys for the AI assistant + web search (Account → API Keys). The DATABASE is the sole
// source of truth for these keys — the old .env keys (JHU_GATEWAY_KEY, TAVILY_API_KEY) are
// deprecated and no longer read. Secrets live encrypted in the UserApiKey table; here we decrypt
// them into a request-scoped AsyncLocalStorage context so the LLM provider and the Tavily tool can
// read the right key WITHOUT threading it through every call. Wrap a request's work in
// runWithUserKeys(userId, …); consumers then call the getters below.
//
// Env still holds INFRASTRUCTURE (not API keys): ENCRYPTION_KEY (decrypts the stored secrets) and an
// optional JHU_GATEWAY_URL override (a non-secret base URL, defaulted below).

import { AsyncLocalStorage } from "node:async_hooks";
import { prisma } from "./prisma";
import { decryptToString } from "./crypto";

export const API_SERVICES = ["bedrock", "jhu-gateway", "openai", "anthropic", "tavily"] as const;
export type ApiService = (typeof API_SERVICES)[number];

export interface ResolvedKey { value?: string; region?: string | null }
type KeyStore = Partial<Record<ApiService, ResolvedKey>>;

const als = new AsyncLocalStorage<KeyStore>();

/** Load + decrypt a user's configured keys into a plain map (server-side only). */
export async function resolveUserKeys(userId: string): Promise<KeyStore> {
  const rows = await prisma.userApiKey.findMany({ where: { userId } });
  const store: KeyStore = {};
  for (const r of rows) {
    if (!(API_SERVICES as readonly string[]).includes(r.service)) continue;
    store[r.service as ApiService] = {
      value: r.valueEnc ? decryptToString(Buffer.from(r.valueEnc)) : undefined,
      region: r.region,
    };
  }
  return store;
}

/** Run `fn` with the user's keys available to the getters below. Nestable; propagates across awaits. */
export async function runWithUserKeys<T>(userId: string, fn: () => Promise<T>): Promise<T> {
  const store = await resolveUserKeys(userId);
  return als.run(store, fn);
}

const ctx = (service: ApiService): ResolvedKey | undefined => als.getStore()?.[service];

// The JHU gateway's public base URL (non-secret). Env can override; default so .env isn't required.
const JHU_URL_DEFAULT = "https://gateway.engineering.jhu.edu/gateway";

/** JHU gateway creds — key comes ONLY from the user's stored key (no env fallback). */
export function jhuCredentials(): { url: string; key: string | undefined } {
  return { url: process.env.JHU_GATEWAY_URL || JHU_URL_DEFAULT, key: ctx("jhu-gateway")?.value };
}

/** Tavily web-search key — ONLY from the user's stored key (no env fallback). */
export function tavilyKey(): string | undefined {
  return ctx("tavily")?.value;
}
