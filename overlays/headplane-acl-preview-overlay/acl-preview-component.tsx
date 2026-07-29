// Replacement component for Headplane's stubbed ACL "preview" tab.
//
// Renders a read-only access matrix (Groups, Access Rules, SSH Rules) parsed
// from the policy JSON that the page already hands to the placeholder. It is
// deliberately self-contained: no extra dependencies beyond React, styling via
// Tailwind utility classes that ship with the app.
//
// The overlay (default.nix) copies this file to app/routes/acls/acl-preview.tsx
// and injects `import AclPreview from "./acl-preview"` into the page. The page
// passes the raw policy string as the `policy` prop.
//
// Treat this as a template — replace the tables with whatever your replaced
// component should render.

import { useMemo } from "react";

interface AclRule {
  action: string;
  src: string[];
  dst: string[];
}

interface AclPolicy {
  groups?: Record<string, string[]>;
  acls?: AclRule[];
  ssh?: Array<{ action: string; src: string[]; dst: string[]; users: string[] }>;
}

function parsePolicy(policy: string): AclPolicy | null {
  try {
    return JSON.parse(policy);
  } catch {
    return null;
  }
}

export default function AclPreview({ policy }: { policy: string }) {
  const parsed = useMemo(() => parsePolicy(policy), [policy]);
  if (!parsed) {
    return (
      <div className="py-4 text-sm text-red-500">
        Unable to parse ACL policy as JSON.
      </div>
    );
  }

  const groups = parsed.groups ?? {};
  const acls = parsed.acls ?? [];
  const ssh = parsed.ssh ?? [];

  const actionClass = (action: string) =>
    action === "accept"
      ? "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200"
      : "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200";

  return (
    <div className="space-y-6 py-4">
      {Object.keys(groups).length > 0 && (
        <div>
          <h3 className="mb-2 text-lg font-medium">Groups</h3>
          <div className="overflow-hidden rounded-lg border border-gray-200 dark:border-gray-700">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-gray-200 bg-gray-50 dark:border-gray-700 dark:bg-gray-800">
                  <th className="px-4 py-2 text-left font-medium">Group</th>
                  <th className="px-4 py-2 text-left font-medium">Members</th>
                </tr>
              </thead>
              <tbody>
                {Object.entries(groups).map(([name, members]) => (
                  <tr key={name} className="border-b border-gray-100 dark:border-gray-800">
                    <td className="px-4 py-2 font-mono text-xs">{name}</td>
                    <td className="px-4 py-2">
                      <div className="flex flex-wrap gap-1">
                        {members.map((m) => (
                          <span key={m} className="rounded bg-blue-100 px-2 py-0.5 text-xs text-blue-800 dark:bg-blue-900 dark:text-blue-200">
                            {m}
                          </span>
                        ))}
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {acls.length > 0 && (
        <div>
          <h3 className="mb-2 text-lg font-medium">Access Rules</h3>
          <div className="overflow-hidden rounded-lg border border-gray-200 dark:border-gray-700">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-gray-200 bg-gray-50 dark:border-gray-700 dark:bg-gray-800">
                  <th className="px-4 py-2 text-left font-medium">Source</th>
                  <th className="px-4 py-2 text-left font-medium">Destination</th>
                  <th className="px-4 py-2 text-left font-medium">Action</th>
                </tr>
              </thead>
              <tbody>
                {acls.map((rule, i) => (
                  <tr key={i} className="border-b border-gray-100 dark:border-gray-800">
                    <td className="px-4 py-2">
                      <div className="flex flex-wrap gap-1">
                        {rule.src.map((s) => (
                          <span key={s} className="rounded bg-orange-100 px-2 py-0.5 text-xs font-mono text-orange-800 dark:bg-orange-900 dark:text-orange-200">
                            {s}
                          </span>
                        ))}
                      </div>
                    </td>
                    <td className="px-4 py-2">
                      <div className="flex flex-wrap gap-1">
                        {rule.dst.map((d) => (
                          <span key={d} className="rounded bg-green-100 px-2 py-0.5 text-xs font-mono text-green-800 dark:bg-green-900 dark:text-green-200">
                            {d}
                          </span>
                        ))}
                      </div>
                    </td>
                    <td className="px-4 py-2">
                      <span className={`rounded px-2 py-0.5 text-xs font-medium ${actionClass(rule.action)}`}>
                        {rule.action}
                      </span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {ssh.length > 0 && (
        <div>
          <h3 className="mb-2 text-lg font-medium">SSH Rules</h3>
          <div className="overflow-hidden rounded-lg border border-gray-200 dark:border-gray-700">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-gray-200 bg-gray-50 dark:border-gray-700 dark:bg-gray-800">
                  <th className="px-4 py-2 text-left font-medium">Source</th>
                  <th className="px-4 py-2 text-left font-medium">Destination</th>
                  <th className="px-4 py-2 text-left font-medium">Users</th>
                  <th className="px-4 py-2 text-left font-medium">Action</th>
                </tr>
              </thead>
              <tbody>
                {ssh.map((rule, i) => (
                  <tr key={i} className="border-b border-gray-100 dark:border-gray-800">
                    <td className="px-4 py-2 font-mono text-xs">{rule.src.join(", ")}</td>
                    <td className="px-4 py-2 font-mono text-xs">{rule.dst.join(", ")}</td>
                    <td className="px-4 py-2 font-mono text-xs">{rule.users.join(", ")}</td>
                    <td className="px-4 py-2">
                      <span className={`rounded px-2 py-0.5 text-xs font-medium ${actionClass(rule.action)}`}>
                        {rule.action}
                      </span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  );
}
