"use server";

import { z } from "zod";
import { revalidatePath } from "next/cache";
import { prisma } from "@/lib/prisma";
import { requireUserId } from "@/lib/auth";
import { PERSON_ROLES } from "@/lib/enums";

const personInput = z.object({
  name: z.string().min(1).max(120),
  email: z.string().email().optional().or(z.literal("")),
  role: z.enum(PERSON_ROLES).optional(),
  affiliation: z.string().max(160).optional(),
  advisorId: z.string().optional().nullable(),
});

export async function listPeople() {
  const userId = await requireUserId();
  return prisma.person.findMany({
    where: { userId },
    orderBy: { name: "asc" },
    include: { advisor: { select: { id: true, name: true } } },
  });
}

export async function getPerson(id: string) {
  const userId = await requireUserId();
  return prisma.person.findFirst({
    where: { id, userId },
    include: {
      advisor: { select: { id: true, name: true } },
      advisees: { select: { id: true, name: true, role: true }, orderBy: { name: "asc" } },
      projects: { include: { project: { select: { id: true, title: true, status: true } } } },
      papers: { include: { paper: { select: { id: true, title: true, status: true } } } },
    },
  });
}

export async function createPerson(input: z.infer<typeof personInput>) {
  const userId = await requireUserId();
  const data = personInput.parse(input);
  const person = await prisma.person.create({
    data: {
      userId,
      name: data.name,
      email: data.email || null,
      role: data.role ?? "OTHER",
      affiliation: data.affiliation || null,
      advisorId: data.advisorId || null,
    },
  });
  revalidatePath("/people");
  return person;
}

const personUpdate = personInput.partial().extend({ id: z.string() });

export async function updatePerson(input: z.infer<typeof personUpdate>) {
  const userId = await requireUserId();
  const { id, ...rest } = personUpdate.parse(input);
  const existing = await prisma.person.findFirst({ where: { id, userId } });
  if (!existing) throw new Error("Person not found");
  if (rest.advisorId === id) throw new Error("A person cannot advise themselves");
  const person = await prisma.person.update({
    where: { id },
    data: {
      ...(rest.name !== undefined ? { name: rest.name } : {}),
      ...(rest.email !== undefined ? { email: rest.email || null } : {}),
      ...(rest.role !== undefined ? { role: rest.role } : {}),
      ...(rest.affiliation !== undefined ? { affiliation: rest.affiliation || null } : {}),
      ...(rest.advisorId !== undefined ? { advisorId: rest.advisorId || null } : {}),
    },
  });
  revalidatePath("/people");
  revalidatePath(`/people/${id}`);
  return person;
}

export async function deletePerson(id: string) {
  const userId = await requireUserId();
  const existing = await prisma.person.findFirst({ where: { id, userId } });
  if (!existing) throw new Error("Person not found");
  await prisma.person.delete({ where: { id } });
  revalidatePath("/people");
}
