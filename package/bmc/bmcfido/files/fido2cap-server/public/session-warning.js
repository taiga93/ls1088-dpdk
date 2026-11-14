(function (window, document) {
  "use strict";

  var WARNING_ENDPOINT = "/api/client-session-status";
  var FETCH_INTERVAL_MS = 30000;
  var TICK_INTERVAL_MS = 1000;

  var panel = document.getElementById("sessionWarningPanel");
  var stateBadge = document.getElementById("sessionWarningState");
  var titleEl = document.getElementById("sessionWarningTitle");
  var messageEl = document.getElementById("sessionWarningMessage");
  var countdownEl = document.getElementById("sessionWarningCountdown");
  var expireEl = document.getElementById("sessionWarningExpiresAt");
  var userEl = document.getElementById("sessionWarningUser");
  var notifyButton = document.getElementById("btnEnableSessionNotification");
  var logoutButton = document.getElementById("btnLogoutSession");
  var toastContainer = document.getElementById("toast-container");

  if (!panel || !stateBadge || !messageEl || !countdownEl || !expireEl || !userEl) {
    return;
  }

  var snapshotRemainingSeconds = null;
  var snapshotTakenAtMs = 0;
  var warningThresholdSeconds = 300;
  var lastWarningKey = null;
  var lastExpiredKey = null;
  var hadActiveSession = false;
  var currentSession = null;
  var logoutRedirectStarted = false;

  function shouldAutoLogoutWhenSessionMissing() {
    return false;
  }

  function redirectToLogout() {
    if (logoutRedirectStarted) {
      return;
    }

    logoutRedirectStarted = true;
    window.location.replace("/logout");
  }

  function showPanel() {
    panel.hidden = false;
  }

  function hidePanel() {
    panel.hidden = true;
    panel.removeAttribute("data-tone");
    updateLogoutButton(false);
  }

  function setState(label, tone) {
    stateBadge.textContent = label;
    stateBadge.setAttribute("data-tone", tone || "info");
    panel.setAttribute("data-tone", tone || "info");

    if (titleEl) {
      if (tone === "success") {
        titleEl.textContent = "Active Session";
      } else if (tone === "warning") {
        titleEl.textContent = "Session Ending Soon";
      } else if (tone === "danger") {
        titleEl.textContent = "Session Expired";
      } else {
        titleEl.textContent = "Session Monitor";
      }
    }
  }

  function updateLogoutButton(isVisible) {
    if (!logoutButton) {
      return;
    }

    logoutButton.hidden = !isVisible;
  }

  function updateNotificationButton(isVisible) {
    if (!notifyButton) {
      return;
    }

    if (!("Notification" in window) || Notification.permission === "granted") {
      notifyButton.hidden = true;
      return;
    }

    notifyButton.hidden = !isVisible;
  }

  function pad(value) {
    return value < 10 ? "0" + value : String(value);
  }

  function formatDuration(totalSeconds) {
    var safeSeconds = Math.max(0, Number(totalSeconds) || 0);
    var days = Math.floor(safeSeconds / 86400);
    var hours = Math.floor((safeSeconds % 86400) / 3600);
    var minutes = Math.floor((safeSeconds % 3600) / 60);
    var seconds = safeSeconds % 60;
    var hhmmss = [pad(hours), pad(minutes), pad(seconds)].join(":");

    return days > 0 ? days + "d " + hhmmss : hhmmss;
  }

  function getLiveRemainingSeconds() {
    if (snapshotRemainingSeconds === null) {
      return null;
    }

    return Math.max(
      0,
      snapshotRemainingSeconds - Math.floor((Date.now() - snapshotTakenAtMs) / 1000)
    );
  }

  function showToast(message, type) {
    var toast;

    if (!toastContainer || !message) {
      return;
    }

    toast = document.createElement("div");
    toast.className = "toast " + (type || "info");
    toast.textContent = message;
    toastContainer.appendChild(toast);

    window.setTimeout(function () {
      toast.style.animation = "fadeOut 0.3s forwards";
      window.setTimeout(function () {
        toast.remove();
      }, 300);
    }, 3500);
  }

  function sendBrowserNotification(title, body, tag) {
    if (!("Notification" in window) || Notification.permission !== "granted") {
      return;
    }

    try {
      new Notification(title, {
        body: body,
        tag: tag,
      });
    } catch (error) {
      console.error("Unable to create browser notification", error);
    }
  }

  function getSessionKey(prefix, session) {
    var ip = session && session.ip ? session.ip : "unknown";
    var expiresAt = session && session.expiresAt !== null ? session.expiresAt : "none";
    return prefix + ":" + ip + ":" + expiresAt;
  }

  function renderInactive(message) {
    hidePanel();
    updateNotificationButton(false);
  }

  function renderSession(session) {
    var remainingSeconds = getLiveRemainingSeconds();
    var warningKey;
    var expiredKey;

    hadActiveSession = true;
    showPanel();
    userEl.textContent = session.user || "unknown";
    expireEl.textContent =
      session.expiresAt !== null
        ? new Date(session.expiresAt * 1000).toLocaleString()
        : "Permanent / no countdown";

    if (remainingSeconds === null) {
      hidePanel();
      updateNotificationButton(false);
      updateLogoutButton(false);
      return;
    }

    updateLogoutButton(true);
    countdownEl.textContent = formatDuration(remainingSeconds);

    if (remainingSeconds === 0) {
      setState("Expired", "danger");
      messageEl.textContent = "Your network access session has expired. Please authenticate again.";
      updateNotificationButton(false);
      updateLogoutButton(true);
      expiredKey = getSessionKey("expired", session);

      if (lastExpiredKey !== expiredKey) {
        lastExpiredKey = expiredKey;
        showToast("Session expired. Please authenticate again.", "error");
        sendBrowserNotification(
          "Session expired",
          "Your network access session has expired. Please authenticate again.",
          expiredKey
        );
      }

      if (shouldAutoLogoutWhenSessionMissing()) {
        window.setTimeout(redirectToLogout, 800);
      }
      return;
    }

    if (remainingSeconds <= warningThresholdSeconds) {
      setState("Ending Soon", "warning");
      messageEl.textContent =
        "Your session will timeout soon. Less than 5 minutes remain before access expires.";
      updateNotificationButton(true);
      warningKey = getSessionKey("warning", session);

      if (lastWarningKey !== warningKey) {
        lastWarningKey = warningKey;
        showToast(
          "Session timeout warning: " + formatDuration(remainingSeconds) + " remaining.",
          "warning"
        );
        sendBrowserNotification(
          "Session timeout warning",
          "Your session will expire in " + formatDuration(remainingSeconds) + ".",
          warningKey
        );
      }
      return;
    }

    setState("Active", "success");
    messageEl.textContent = "Your FIDO network access session is active.";
    updateNotificationButton(false);
  }

  function applyPayload(payload) {
    var session = payload && payload.session ? payload.session : null;

    warningThresholdSeconds = 300;

    if (!session) {
      if (shouldAutoLogoutWhenSessionMissing()) {
        redirectToLogout();
        return;
      }

      if (hadActiveSession) {
        var missingKey = "missing-session";
        showPanel();
        setState("Expired", "danger");
        messageEl.textContent = "No active authorized session was found. Your access may have expired.";
        countdownEl.textContent = "00:00:00";
        expireEl.textContent = "--";
        userEl.textContent = "--";
        updateNotificationButton(false);
        updateLogoutButton(false);
        if (lastExpiredKey !== missingKey) {
          lastExpiredKey = missingKey;
          showToast("Session no longer active. Please authenticate again.", "error");
          sendBrowserNotification(
            "Session expired",
            "No active authorized session was found. Please authenticate again.",
            missingKey
          );
        }
      } else {
        renderInactive(payload && payload.message);
      }
      currentSession = null;
      snapshotRemainingSeconds = null;
      return;
    }

    currentSession = session;
    snapshotRemainingSeconds =
      session.remainingSeconds === null ? null : Number(session.remainingSeconds);
    snapshotTakenAtMs = Date.now();
    renderSession(session);
  }

  function fetchSessionStatus() {
    return fetch(WARNING_ENDPOINT, {
      method: "GET",
      cache: "no-store",
      credentials: "same-origin",
    })
      .then(function (response) {
        if (!response.ok) {
          throw new Error("HTTP " + response.status);
        }

        return response.json();
      })
      .then(function (payload) {
        applyPayload(payload);
      })
      .catch(function (error) {
        console.error("Unable to load client session status", error);
      });
  }

  if (logoutButton) {
    logoutButton.addEventListener("click", function () {
      if (window.confirm("Log out this FIDO session?")) {
        redirectToLogout();
      }
    });
  }

  if (notifyButton) {
    notifyButton.addEventListener("click", function () {
      if (!("Notification" in window)) {
        showToast("This browser does not support browser notifications.", "error");
        return;
      }

      Notification.requestPermission().then(function (permission) {
        if (permission === "granted") {
          showToast("Browser notifications enabled.", "success");
        } else if (permission === "denied") {
          showToast("Browser notifications were denied.", "error");
        } else {
          showToast("Browser notification permission dismissed.", "info");
        }
      });
    });
  }

  fetchSessionStatus();
  window.setInterval(fetchSessionStatus, FETCH_INTERVAL_MS);
  window.setInterval(function () {
    if (currentSession) {
      renderSession(currentSession);
    }
  }, TICK_INTERVAL_MS);
})(window, document);
