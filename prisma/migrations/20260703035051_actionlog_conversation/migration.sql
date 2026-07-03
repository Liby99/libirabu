-- AlterTable
ALTER TABLE "ActionLog" ADD COLUMN     "conversationId" TEXT;

-- CreateIndex
CREATE INDEX "ActionLog_userId_conversationId_idx" ON "ActionLog"("userId", "conversationId");
