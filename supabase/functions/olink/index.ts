// RSO ⇔ O-Link（大房の登録支援機関マイページ）の中継
// - RSOにログインしていて、停止されていない人だけが使える
// - その機関のO-Linkの鍵（トークン・パスワード）は olink_links にだけあり、ここで付け足す。画面（ブラウザ）には渡さない
// - 大房のDBには、O-Link（share.html）が使っているのと同じ公開窓口だけを通す。鍵の付け替えは「p_token / p_pass」などO-Linkの鍵の欄だけ
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const ANKEN_URL = "https://ehwlgbwpycglmopiqyty.supabase.co";
const ANKEN_KEY = "sb_publishable_3ptyILIpGIcNA5sUBhFMbA_n0VxpY2u"; // O-Link（share.html）に載っている公開キー
const GAS_PREFIX = "https://script.google.com/macros/s/AKfycbxxBta5g1jXVzTf-s4EgaIbMc3No42aaH8guMOorQQ8HZl2SlNu-8vpu0fCFj_rjKsalQ/exec";
const FN_ALLOW = ["intake-ai-read"];

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json; charset=utf-8" } });
const fail = (message: string, status = 400) => json({ ok: false, message }, status);

async function ankenRpc(name: string, body: unknown) {
  const r = await fetch(`${ANKEN_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: { apikey: ANKEN_KEY, Authorization: `Bearer ${ANKEN_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify(body ?? {}),
  });
  const text = await r.text();
  return { status: r.status, text, type: r.headers.get("content-type") || "application/json" };
}
function tokenFrom(input: string) {
  const s = String(input || "").trim();
  const m = s.match(/[?&]token=([^&#\s]+)/);
  return decodeURIComponent(m ? m[1] : s);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return fail("method", 405);
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: who } = await sb.auth.getUser(jwt);
  if (!who?.user) return fail("ログインし直してください", 401);
  const { data: me } = await sb.from("members").select("org_id, role, active, display_name").eq("user_id", who.user.id).maybeSingle();
  if (!me || me.active === false) return fail("このアカウントは使えません", 403);

  let body: Record<string, any> = {};
  try { body = await req.json(); } catch { /* 空 */ }
  const action = String(body.action || "");

  try {
    // ---------- 運営：連携の一覧・設定・解除 ----------
    if (action === "admin_list" || action === "admin_set" || action === "admin_unset") {
      if (me.role !== "operator") return fail("運営だけが使えます", 403);
      if (action === "admin_list") {
        const { data } = await sb.from("olink_links").select("org_id, olink_name, linked_at, linked_by");
        return json({ ok: true, links: data || [] });
      }
      const orgId = String(body.orgId || "");
      const { data: org } = await sb.from("orgs").select("id, name").eq("id", orgId).maybeSingle();
      if (!org) return fail("登録支援機関が見つかりません");
      if (action === "admin_unset") {
        await sb.from("olink_links").delete().eq("org_id", orgId);
        return json({ ok: true });
      }
      const token = tokenFrom(body.url);
      const pass = String(body.pass || "").trim();
      if (!/^[A-Za-z0-9_-]{6,}$/.test(token)) return fail("O-LinkのURL（または token= の後ろ）を入れてください");
      const meta = await ankenRpc("get_org_meta", { p_token: token });
      let m: any = null; try { m = JSON.parse(meta.text); } catch { /* */ }
      if (!m || !m.orgName) return fail("このO-LinkのURLは無効です");
      if (m.hasPass) {
        const chk = await ankenRpc("get_org_notifications", { p_token: token, p_pass: pass || null });
        let c: any = null; try { c = JSON.parse(chk.text); } catch { /* */ }
        if (!c || (c && !Array.isArray(c) && c.error)) return fail("O-Linkのパスワードが違います");
      }
      const { error } = await sb.from("olink_links").upsert({
        org_id: orgId, token, pass: pass || null, olink_name: m.orgName,
        linked_at: new Date().toISOString(), linked_by: me.display_name || who.user.email,
      });
      if (error) return fail("保存できませんでした：" + error.message, 500);
      return json({ ok: true, olinkName: m.orgName });
    }

    // ---------- だれでも：連携しているか ----------
    const { data: link } = await sb.from("olink_links").select("token, pass, olink_name").eq("org_id", me.org_id).maybeSingle();
    if (action === "status") return json({ ok: true, linked: !!link, name: link?.olink_name || "" });
    if (!link) return fail("この登録支援機関は、まだO-Linkと連携していません（運営に依頼してください）", 404);

    // ---------- 中継 ----------
    if (action !== "call") return fail("不明な操作です");
    const kind = String(body.kind || "");

    if (kind === "rpc") {
      const name = String(body.name || "");
      if (!/^[a-z0-9_]{1,64}$/.test(name)) return fail("不明な処理です");
      const b = (body.body && typeof body.body === "object") ? { ...body.body } : {};
      // O-Linkの鍵の欄だけ、この機関の鍵に差し替える（画面から来た値は使わない）
      if ("p_token" in b) b.p_token = link.token;
      if ("p_pass" in b) b.p_pass = link.pass || null;
      const r = await ankenRpc(name, b);
      let text = r.text;
      if (name === "get_org_meta") { // パスワード画面を出さない（鍵はここで付けるため）
        try { const m = JSON.parse(text); if (m && typeof m === "object") { m.hasPass = false; text = JSON.stringify(m); } } catch { /* */ }
      }
      return json({ ok: true, status: r.status, type: r.type, body: text });
    }
    if (kind === "fn") {
      const name = String(body.name || "");
      if (!FN_ALLOW.includes(name)) return fail("不明な処理です");
      const b = (body.body && typeof body.body === "object") ? { ...body.body } : {};
      if ("token" in b) b.token = link.token;
      if ("pass" in b) b.pass = link.pass || "";
      const r = await fetch(`${ANKEN_URL}/functions/v1/${name}`, {
        method: "POST", headers: { apikey: ANKEN_KEY, "Content-Type": "application/json" }, body: JSON.stringify(b),
      });
      return json({ ok: true, status: r.status, type: r.headers.get("content-type") || "application/json", body: await r.text() });
    }
    if (kind === "sign") { // お知らせの添付PDF（5分だけ有効なURLを出す）
      const path = String(body.path || "");
      if (!/^news-files\/[^?#]+$/.test(path) || path.includes("..")) return fail("不明なファイルです");
      const r = await fetch(`${ANKEN_URL}/storage/v1/object/sign/${path}`, {
        method: "POST", headers: { apikey: ANKEN_KEY, Authorization: `Bearer ${ANKEN_KEY}`, "Content-Type": "application/json" },
        body: JSON.stringify({ expiresIn: 300 }),
      });
      return json({ ok: true, status: r.status, type: r.headers.get("content-type") || "application/json", body: await r.text() });
    }
    if (kind === "gas") { // 書類の閲覧（大房のGAS getOrgDoc）
      const url = new URL(String(body.url || ""));
      if (!(url.origin + url.pathname).startsWith(GAS_PREFIX)) return fail("不明な宛先です");
      const raw = url.searchParams.get("jsonpPost");
      if (!raw) return fail("不明な依頼です");
      const p = JSON.parse(raw);
      if (!p || p.action !== "getOrgDoc" || !p.data) return fail("不明な依頼です");
      p.data.token = link.token; p.data.pass = link.pass || "";
      url.searchParams.set("jsonpPost", JSON.stringify(p));
      const r = await fetch(url.toString(), { redirect: "follow" });
      return json({ ok: true, status: r.status, type: r.headers.get("content-type") || "text/plain", body: await r.text() });
    }
    return fail("不明な通信です");
  } catch (e) {
    return fail("O-Linkとの通信でエラーが起きました：" + (e as Error).message, 500);
  }
});
