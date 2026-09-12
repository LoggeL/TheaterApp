// Generated public config comes from tool/configure.mjs before a web build.
importScripts('/firebase-web-config.js');
if (self.theaterFirebaseConfig?.projectId) {
  importScripts('https://www.gstatic.com/firebasejs/12.18.0/firebase-app-compat.js');
  importScripts('https://www.gstatic.com/firebasejs/12.18.0/firebase-messaging-compat.js');
  firebase.initializeApp(self.theaterFirebaseConfig);
  firebase.messaging();
}
