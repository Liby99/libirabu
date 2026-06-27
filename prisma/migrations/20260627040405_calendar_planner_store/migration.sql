-- CreateTable
CREATE TABLE "CalendarItem" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "kind" TEXT NOT NULL,
    "title" TEXT NOT NULL,
    "notes" TEXT,
    "color" TEXT NOT NULL DEFAULT 'default',
    "start" TIMESTAMP(3) NOT NULL,
    "end" TIMESTAMP(3) NOT NULL,
    "track" INTEGER,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "CalendarItem_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "CalendarPrefs" (
    "userId" TEXT NOT NULL,
    "mainTz" TEXT NOT NULL DEFAULT 'America/New_York',
    "altTz" TEXT,
    "trackNames" JSONB NOT NULL,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "CalendarPrefs_pkey" PRIMARY KEY ("userId")
);

-- CreateIndex
CREATE INDEX "CalendarItem_userId_start_idx" ON "CalendarItem"("userId", "start");
