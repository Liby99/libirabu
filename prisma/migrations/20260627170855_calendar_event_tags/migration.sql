-- AlterTable
ALTER TABLE "CalendarItem" ADD COLUMN     "tags" TEXT[] DEFAULT ARRAY[]::TEXT[];
