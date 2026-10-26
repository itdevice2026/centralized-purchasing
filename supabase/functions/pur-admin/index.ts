// Centralized Purchasing — user account management (Module Admin only)
// actions: create (creates or links a login + purchasing profile; always applies the typed password), reset (sets a new password)
import { createClient } from 'jsr:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, 'Content-Type': 'application/json' } });
const ROLES = ['admin', 'purchasing', 'requester', 'receiver', 'viewer', 'executive', 'accounting'];

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const svc = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
    const authz = req.headers.get('Authorization') || '';
    const caller = createClient(url, anon, { global: { headers: { Authorization: authz } }, auth: { persistSession: false } });
    const { data: isAdmin, error: re } = await caller.rpc('pur_is_admin');
    if (re || !isAdmin) return json({ error: 'Only the Module Admin can manage users.' }, 403);

    const admin = createClient(url, svc, { auth: { persistSession: false } });
    const body = await req.json();
    const { action } = body;

    if (action === 'create') {
      const email = String(body.email || '').trim().toLowerCase();
      const full_name = String(body.full_name || '').trim();
      const role = String(body.role || 'requester');
      const companies: string[] = Array.isArray(body.company_ids) ? body.company_ids : [];
      if (!email || !email.includes('@')) return json({ error: 'A valid email is required.' }, 400);
      if (!full_name) return json({ error: 'Full name is required.' }, 400);
      if (!ROLES.includes(role)) return json({ error: 'Invalid role.' }, 400);

      let userId: string | null = null;
      let linked = false;
      let passwordSet = false;
      const password = String(body.password || '');
      if (password && password.length < 8) return json({ error: 'Password must be at least 8 characters.' }, 400);
      const { data: found } = await admin.rpc('pur_find_user', { p_email: email });
      if (found) {
        // Existing login (shared with Resolve-IT / other Meatplus apps): link it, and apply the typed password if given.
        userId = found as string;
        linked = true;
        const { data: already } = await admin.from('pur_profiles').select('user_id').eq('user_id', userId).maybeSingle();
        if (already) return json({ error: 'This user is already in the Purchasing System.' }, 409);
        if (password) {
          const { data: cur } = await admin.auth.admin.getUserById(userId);
          const meta = { ...(cur?.user?.user_metadata || {}), pur_must_change: true };
          const { error: pe2 } = await admin.auth.admin.updateUserById(userId, { password, user_metadata: meta, email_confirm: true });
          if (pe2) return json({ error: pe2.message }, 400);
          passwordSet = true;
        }
      } else {
        if (!password) return json({ error: 'Enter a temporary password (at least 8 characters) for the new login.' }, 400);
        const { data, error } = await admin.auth.admin.createUser({
          email, password, email_confirm: true,
          user_metadata: { full_name, pur_must_change: true },
        });
        if (error) {
          if (/database error/i.test(error.message || '')) {
            return json({ error: 'Account was refused by the database. Logins must use an @meatplus.ph email or an email on file in the HRIS masterfile.' }, 400);
          }
          return json({ error: error.message }, 400);
        }
        userId = data.user.id;
        passwordSet = true;
      }
      const { data: exists } = await admin.from('pur_profiles').select('user_id').eq('user_id', userId).maybeSingle();
      if (exists) return json({ error: 'This user is already in the Purchasing System.' }, 409);
      const { error: pe } = await admin.from('pur_profiles').insert({
        user_id: userId, email, full_name, role, position: String(body.position || ''),
        module_access: ['Both', 'Trade', 'Non-Trade'].includes(body.module_access) ? body.module_access : 'Both',
      });
      if (pe) return json({ error: pe.message }, 400);
      if (companies.length) {
        await admin.from('pur_user_companies').insert(companies.map((c) => ({ user_id: userId, company_id: c })));
      }
      return json({ ok: true, user_id: userId, linked, password_set: passwordSet });
    }

    if (action === 'reset') {
      const userId = String(body.user_id || '');
      const password = String(body.password || '');
      if (password.length < 8) return json({ error: 'Password must be at least 8 characters.' }, 400);
      const { data: prof } = await admin.from('pur_profiles').select('user_id').eq('user_id', userId).maybeSingle();
      if (!prof) return json({ error: 'User not found in the Purchasing System.' }, 404);
      const { data: cur, error: ge } = await admin.auth.admin.getUserById(userId);
      if (ge) return json({ error: ge.message }, 400);
      const meta = { ...(cur.user?.user_metadata || {}), pur_must_change: true };
      const { error } = await admin.auth.admin.updateUserById(userId, { password, user_metadata: meta });
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true });
    }

    return json({ error: 'Unknown action.' }, 400);
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
