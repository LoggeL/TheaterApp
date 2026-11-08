export const escapeHtml = value => String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

/** Table layout and inline styles also work when a mail client removes CSS.
 * No remote images, fonts or tracking. Every dynamic value is escaped here.
 */
export function theaterEmailHtml({ preview, eyebrow, title, body, details = [], actionLabel, actionUrl, footer }) {
  return `<!doctype html>
<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${escapeHtml(title)}</title></head>
<body style="margin:0;padding:0;background-color:#f8f6f0;color:#202823;font-family:Arial,Helvetica,sans-serif;-webkit-text-size-adjust:100%">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;mso-hide:all">${escapeHtml(preview)}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color:#f8f6f0"><tr><td align="center" style="padding:28px 12px">
<!--[if mso]><table role="presentation" width="560"><tr><td><![endif]-->
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background-color:#ffffff;border:1px solid #e4e5df;border-radius:20px;overflow:hidden">
<tr><td style="padding:28px;background-color:#202823;border-bottom:4px solid #e96131">
<p style="margin:0;color:#ffffff;font-size:22px;line-height:1.3;font-weight:700">Theater-App</p>
<p style="margin:6px 0 0;color:#cbd2cc;font-size:13px;line-height:1.5">Kolpingtheater Ramsen</p>
</td></tr>
<tr><td style="padding:28px">
<p style="margin:0 0 12px;color:#b13c15;font-size:12px;line-height:1.5;font-weight:700;letter-spacing:1px;text-transform:uppercase">${escapeHtml(eyebrow)}</p>
<h1 style="margin:0 0 18px;font-size:28px;line-height:1.2;letter-spacing:-.5px;font-weight:700;overflow-wrap:anywhere">${escapeHtml(title)}</h1>
<p style="margin:0;font-size:16px;line-height:1.65;overflow-wrap:anywhere">${escapeHtml(body)}</p>
${details.length ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-top:24px;background-color:#f8f6f0;border-radius:12px"><tr><td style="padding:18px 20px">${details.map(([label, value]) => `<p style="margin:0 0 4px;color:#5b665e;font-size:12px;line-height:1.5">${escapeHtml(label)}</p><p style="margin:0 0 12px;font-size:16px;line-height:1.5;font-weight:700;overflow-wrap:anywhere">${escapeHtml(value)}</p>`).join('')}</td></tr></table>` : ''}
<table role="presentation" cellpadding="0" cellspacing="0" style="margin-top:28px"><tr><td bgcolor="#cb4516" style="border-radius:10px;text-align:center;mso-padding-alt:16px 24px"><a href="${escapeHtml(actionUrl)}" style="display:inline-block;padding:16px 24px;border:1px solid #cb4516;border-radius:10px;background-color:#cb4516;color:#ffffff;font-size:16px;line-height:1.4;font-weight:700;text-decoration:none">${escapeHtml(actionLabel)}</a></td></tr></table>
</td></tr>
<tr><td style="padding:22px 28px;border-top:1px solid #e4e5df"><p style="margin:0;color:#5b665e;font-size:13px;line-height:1.6">${escapeHtml(footer)}</p></td></tr>
</table>
<!--[if mso]></td></tr></table><![endif]-->
<p style="margin:20px 0 0;color:#5b665e;font-size:12px;line-height:1.5">Kolpingtheater Ramsen · Theater-App</p>
</td></tr></table></body></html>`;
}

// Firebase replaces %LINK% only when sending. Verification/change-email bodies
// are managed by Firebase and cannot be freely customized like this reset body.
export function firebasePasswordResetTemplate() {
  return {
    subject: 'Dein neues Passwort für die Theater-App',
    bodyFormat: 'HTML',
    body: theaterEmailHtml({
      preview: 'Hier kannst du ein neues Passwort für dein Theater-Konto festlegen.',
      eyebrow: 'Dein Konto',
      title: 'Ein neues Passwort für dich.',
      body: 'Du hast einen Link zum Zurücksetzen deines Passworts angefordert. Öffne ihn, um ein neues Passwort für die Theater-App festzulegen.',
      actionLabel: 'Neues Passwort festlegen',
      actionUrl: '%LINK%',
      footer: 'Du hast das nicht angefordert? Dann kannst du diese E-Mail ignorieren. Dein Passwort bleibt unverändert.',
    }),
  };
}
