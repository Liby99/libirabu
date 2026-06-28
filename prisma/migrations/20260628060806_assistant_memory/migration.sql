-- CreateTable
CREATE TABLE "AssistantMemory" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "key" TEXT NOT NULL,
    "value" JSONB NOT NULL,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "AssistantMemory_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "AssistantMemory_userId_idx" ON "AssistantMemory"("userId");

-- CreateIndex
CREATE UNIQUE INDEX "AssistantMemory_userId_key_key" ON "AssistantMemory"("userId", "key");
