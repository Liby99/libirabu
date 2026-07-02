-- AlterTable
ALTER TABLE "CalendarItem" ADD COLUMN     "connectionId" TEXT,
ADD COLUMN     "externalEtag" TEXT,
ADD COLUMN     "externalId" TEXT,
ADD COLUMN     "externalUid" TEXT,
ADD COLUMN     "externalUrl" TEXT,
ADD COLUMN     "importedAt" TIMESTAMP(3),
ADD COLUMN     "source" TEXT NOT NULL DEFAULT 'manual';

-- CreateTable
CREATE TABLE "CalendarConnection" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "provider" TEXT NOT NULL,
    "accountLabel" TEXT NOT NULL,
    "externalCalId" TEXT NOT NULL,
    "calName" TEXT NOT NULL,
    "color" TEXT,
    "accessTokenEnc" BYTEA,
    "refreshTokenEnc" BYTEA,
    "expiresAt" INTEGER,
    "syncToken" TEXT,
    "lastSyncedAt" TIMESTAMP(3),
    "enabled" BOOLEAN NOT NULL DEFAULT true,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "CalendarConnection_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "CalendarConnection_userId_idx" ON "CalendarConnection"("userId");

-- CreateIndex
CREATE UNIQUE INDEX "CalendarConnection_userId_provider_externalCalId_key" ON "CalendarConnection"("userId", "provider", "externalCalId");

-- CreateIndex
CREATE UNIQUE INDEX "CalendarItem_userId_connectionId_externalUid_key" ON "CalendarItem"("userId", "connectionId", "externalUid");

