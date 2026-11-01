import { AppError } from './theater.mjs';

// Firebase owns the action code and its browser form. Only the resulting link
// leaves this call; neither the code nor the link is stored in our database.
export async function createPasswordResetLink(theater, uid, targetUid, version, auth) {
  const check = () => {
    theater.account(uid, true);
    const target = theater.store.account(targetUid);
    if (!target || target.version !== version) throw new AppError(409, 'Das Konto hat sich geändert. Bitte neu laden.', 'version_conflict');
    if (targetUid === uid) throw new AppError(409, 'Für dein eigenes Konto nutze bitte „Passwort vergessen“ bei der Anmeldung.');
    return target;
  };
  const target = check();
  if (!auth) throw new AppError(409, 'Passwort-Links sind auf diesem Server nicht eingerichtet.', 'password_reset_unavailable');
  try {
    const user = await auth.getUser(targetUid);
    check();
    if (user.disabled) throw new AppError(409, 'Das Anmeldekonto ist bei Firebase gesperrt.');
    if (!user.email || !user.providerData.some(p => p.providerId === 'password')) {
      throw new AppError(409, 'Dieses Konto nutzt keine Anmeldung mit E-Mail und Passwort. Das Passwort wird beim Anmeldeanbieter geändert.', 'password_provider_required');
    }
    if (user.email !== target.email) throw new AppError(409, 'Die Login-Adresse hat sich geändert. Bitte den Kontostand aktualisieren.', 'version_conflict');
    const link = await auth.generatePasswordResetLink(user.email);
    // Rights, account state or email may have changed while Firebase answered.
    const current = check();
    if (current.email !== target.email) throw new AppError(409, 'Das Konto hat sich geändert. Bitte neu laden.', 'version_conflict');
    theater.store.audit(uid, 'account.passwordResetLink', targetUid);
    return { link, email: user.email };
  } catch (error) {
    if (error instanceof AppError) throw error;
    if (error.code === 'auth/user-not-found') throw new AppError(404, 'Das Anmeldekonto wurde nicht gefunden.');
    if (error.code === 'auth/too-many-requests' || error.code === 'auth/quota-exceeded') throw new AppError(429, 'Zu viele Passwort-Anfragen. Bitte später erneut versuchen.');
    // Provider errors can contain request details. Keep them out of responses
    // and the HTTP error log, which would otherwise print their message.
    throw new AppError(503, 'Der Passwort-Link konnte gerade nicht erzeugt werden. Bitte erneut versuchen.', 'password_reset_unavailable');
  }
}
