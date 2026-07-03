-- CreateTable
CREATE TABLE "UserApiKey" (
    "userId" TEXT NOT NULL,
    "service" TEXT NOT NULL,
    "valueEnc" BYTEA,
    "last4" TEXT,
    "region" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "UserApiKey_pkey" PRIMARY KEY ("userId","service")
);

-- CreateIndex
CREATE INDEX "UserApiKey_userId_idx" ON "UserApiKey"("userId");
