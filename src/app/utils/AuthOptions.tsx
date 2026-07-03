import { prisma } from "@/lib/prisma";
import { PrismaAdapter } from "@next-auth/prisma-adapter";
import CredentialsProvider from "next-auth/providers/credentials";
import bcrypt from "bcryptjs";

// Login is email + password only (credentials). No third-party providers.
const authOptions = {
  // Prisma 7's generated client type differs nominally from the @prisma/client
  // type that @next-auth/prisma-adapter is typed against, though the runtime
  // model methods are identical. Cast to the adapter's expected client type.
  adapter: PrismaAdapter(prisma as unknown as Parameters<typeof PrismaAdapter>[0]),
  providers: [
    CredentialsProvider({
      name: "credentials",
      credentials: {
        email: { label: "Email", type: "email" },
        password: { label: "Password", type: "password" }
      },
      async authorize(credentials) {
        if (!credentials?.email || !credentials?.password) return null;
        const user = await prisma.user.findUnique({ where: { email: credentials.email } });
        if (user && user.password && await bcrypt.compare(credentials.password, user.password)) {
          return { id: user.id, email: user.email, name: user.name };
        }
        return null;
      }
    }),
  ],
  session: {
    strategy: "jwt" as const,
  },
  callbacks: {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    async session({ session, token }: any) {
      if (token.sub && session.user) {
        session.user.id = token.sub
      }
      return session
    },
  },
  pages: {
    signIn: "/auth/signin",
  },
}

export { authOptions }
