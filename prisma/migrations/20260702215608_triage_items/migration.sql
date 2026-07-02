-- CreateTable
CREATE TABLE "TriageItem" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "source" TEXT NOT NULL,
    "connectionId" TEXT,
    "dedupKey" TEXT NOT NULL,
    "payload" JSONB NOT NULL,
    "candidates" JSONB NOT NULL,
    "suggestion" JSONB,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "TriageItem_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "TriageItem_userId_idx" ON "TriageItem"("userId");

-- CreateIndex
CREATE UNIQUE INDEX "TriageItem_userId_dedupKey_key" ON "TriageItem"("userId", "dedupKey");
