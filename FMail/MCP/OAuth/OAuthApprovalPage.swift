import Foundation

/// Minimal HTML rendered at `GET /authorize`. Two variants depending on
/// whether the approval window is currently open in FMail Settings:
///
///   - **Closed**: tells the user to open the window in FMail first;
///     no approve button rendered.
///   - **Open**: shows what's being authorized + Approve / Deny buttons
///     that POST to `/authorize/approve` and `/authorize/deny` with the
///     original query parameters echoed back as form fields so the
///     server can reconstitute the full authorization request.
///
/// Plain HTML/CSS — no JavaScript, no external assets. The page is
/// served over Cloudflare's TLS edge, so the browser already trusts the
/// connection. Keeping the inline style sparse so we don't get into a
/// CSP-tightening rabbit hole.
enum OAuthApprovalPage {

    struct Context {
        let clientID: String
        let clientName: String?
        let redirectURI: String
        let state: String
        let codeChallenge: String
        let codeChallengeMethod: String
        let scope: String?
        let windowState: OAuthStore.ApprovalWindowState
    }

    static func render(_ ctx: Context) -> String {
        let baseCSS = """
        body { font-family: -apple-system, BlinkMacSystemFont, "SF Pro", sans-serif;
               background: #f5f5f7; color: #1d1d1f; margin: 0;
               display: flex; align-items: center; justify-content: center; min-height: 100vh; }
        .card { background: white; padding: 32px 36px; max-width: 480px;
                border-radius: 12px; box-shadow: 0 4px 24px rgba(0,0,0,0.08); }
        h1 { margin: 0 0 8px; font-size: 22px; }
        h2 { margin: 16px 0 4px; font-size: 13px; text-transform: uppercase;
             color: #86868b; font-weight: 600; letter-spacing: 0.04em; }
        .field { margin: 0 0 12px; font-family: ui-monospace, SFMono-Regular, monospace;
                 font-size: 13px; color: #1d1d1f; word-break: break-all; }
        .actions { margin-top: 24px; display: flex; gap: 12px; }
        button { font: inherit; padding: 10px 20px; border-radius: 8px;
                 border: 1px solid #d2d2d7; background: white; cursor: pointer; }
        button.primary { background: #0071e3; color: white; border-color: #0071e3; }
        button.primary:hover { background: #0077ed; }
        .warn { padding: 12px 16px; background: #fff8e6; border: 1px solid #f5d76e;
                color: #8a6d1f; border-radius: 8px; margin-bottom: 16px; font-size: 14px; }
        .danger { padding: 12px 16px; background: #ffe7e6; border: 1px solid #ff8c87;
                  color: #8a1f1f; border-radius: 8px; margin-bottom: 16px; font-size: 14px; }
        form { margin: 0; display: inline; }
        """

        let displayClient = (ctx.clientName?.isEmpty == false ? ctx.clientName! : ctx.clientID)
        let escapedClient = escape(displayClient)
        let escapedRedirect = escape(ctx.redirectURI)
        let escapedScope = escape(ctx.scope ?? "(default)")

        let body: String
        if case .open(let secs) = ctx.windowState {
            body = """
            <p>An MCP client is asking to connect to your FMail index. Approve only if you started this from FMail Settings.</p>

            <h2>Client</h2>
            <div class="field">\(escapedClient)</div>

            <h2>Redirect URI</h2>
            <div class="field">\(escapedRedirect)</div>

            <h2>Scope</h2>
            <div class="field">\(escapedScope)</div>

            <h2>Approval window</h2>
            <div class="field">Open — closes in \(secs)s, or immediately after one approval.</div>

            <div class="actions">
                \(approveForm(ctx))
                \(denyForm(ctx))
            </div>
            """
        } else {
            body = """
            <div class="warn">
                <strong>Approval window is closed.</strong><br>
                Open FMail → Settings → MCP Server → <em>OAuth pairing</em>, then click
                <em>Open approval window (5 min)</em>. Refresh this page after.
            </div>

            <h2>Client</h2>
            <div class="field">\(escapedClient)</div>

            <h2>Redirect URI</h2>
            <div class="field">\(escapedRedirect)</div>

            <div class="actions">
                <button onclick="location.reload()">Refresh</button>
            </div>
            """
        }

        return """
        <!doctype html>
        <html lang="en">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Authorize FMail connector</title>
            <style>\(baseCSS)</style>
        </head>
        <body>
            <div class="card">
                <h1>FMail · Authorize connector</h1>
                \(body)
            </div>
        </body>
        </html>
        """
    }

    /// Simple error page rendered when /authorize parameters are bad —
    /// e.g. unsupported response_type, malformed redirect_uri.
    static func renderError(message: String) -> String {
        let escaped = escape(message)
        return """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><title>FMail · Authorization error</title></head>
        <body style="font-family: -apple-system, sans-serif; padding: 32px;">
            <h1>Authorization error</h1>
            <p>\(escaped)</p>
        </body>
        </html>
        """
    }

    private static func approveForm(_ ctx: Context) -> String {
        formWithHiddenFields(action: "/authorize/approve", ctx: ctx, button: "Approve", primary: true)
    }

    private static func denyForm(_ ctx: Context) -> String {
        formWithHiddenFields(action: "/authorize/deny", ctx: ctx, button: "Deny", primary: false)
    }

    private static func formWithHiddenFields(action: String, ctx: Context, button: String, primary: Bool) -> String {
        let cls = primary ? "primary" : ""
        return """
        <form method="POST" action="\(action)">
            <input type="hidden" name="client_id" value="\(escape(ctx.clientID))">
            <input type="hidden" name="redirect_uri" value="\(escape(ctx.redirectURI))">
            <input type="hidden" name="state" value="\(escape(ctx.state))">
            <input type="hidden" name="code_challenge" value="\(escape(ctx.codeChallenge))">
            <input type="hidden" name="code_challenge_method" value="\(escape(ctx.codeChallengeMethod))">
            <input type="hidden" name="scope" value="\(escape(ctx.scope ?? ""))">
            <button type="submit" class="\(cls)">\(button)</button>
        </form>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
