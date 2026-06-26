import { requireUserId } from "@/lib/auth";
import { listApiKeys } from "@/app/actions/apikeys";
import { listPeople } from "@/app/actions/people";
import AppNav from "@/app/components/app/AppNav";
import KeysManager from "@/app/components/keys/KeysManager";

export default async function KeysPage() {
  await requireUserId();
  const [keys, people] = await Promise.all([listApiKeys(), listPeople()]);
  return (
    <>
      <AppNav />
      <main className="app-main app-scroll">
        <KeysManager
          keys={keys}
          people={people.map((p) => ({ id: p.id, name: p.name }))}
        />
      </main>
    </>
  );
}
