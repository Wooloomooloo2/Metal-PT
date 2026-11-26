// The 404 page: unknown routes, game slugs, run ids, Mac and setup keys.
import { Layout } from "./layout.tsx";

export function NotFoundPage(props: { what?: string }) {
  return (
    <Layout title="Not found">
      <section class="stack" style="gap:12px">
        <h1>Not found</h1>
        <p class="muted">{props.what ?? "There's no page here."} It may have been removed by the person who published it.</p>
        <p>
          <a href="/">Back to the games</a>
        </p>
      </section>
    </Layout>
  );
}
