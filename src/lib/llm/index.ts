import type { LLMProvider } from "./types";
import { JhuGatewayProvider } from "./jhuGateway";

export * from "./types";

// Single place to choose the active provider. Swap here for Bedrock/Anthropic later.
let provider: LLMProvider | undefined;

export function getLLM(): LLMProvider {
  if (!provider) provider = new JhuGatewayProvider();
  return provider;
}
