-- CreateTable
CREATE TABLE "DailyNote" (
    "userId" TEXT NOT NULL,
    "date" TEXT NOT NULL,
    "notes" TEXT NOT NULL,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "DailyNote_pkey" PRIMARY KEY ("userId","date")
);

-- CreateIndex
CREATE INDEX "DailyNote_userId_idx" ON "DailyNote"("userId");
