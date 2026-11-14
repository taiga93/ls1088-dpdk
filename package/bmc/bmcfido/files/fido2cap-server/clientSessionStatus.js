const fs = require("fs");
const path = require("path");
const { execFile } = require("child_process");

const WARNING_THRESHOLD_SECONDS = 300;

function getClientIP(req) {
  let clientIP = req.headers["x-forwarded-for"];

  if (Array.isArray(clientIP)) {
    clientIP = clientIP[0];
  } else if (typeof clientIP === "string") {
    clientIP = clientIP.split(",")[0].trim();
  }

  clientIP =
    clientIP ||
    req.socket?.remoteAddress ||
    req.connection?.remoteAddress ||
    req.ip ||
    "";

  if (typeof clientIP !== "string") {
    clientIP = String(clientIP || "");
  }

  clientIP = clientIP.replace(/^::ffff:/, "").trim();

  if (clientIP === "::1") {
    clientIP = "127.0.0.1";
  }

  return clientIP;
}

function getStatusScriptPath() {
  const scriptCandidates = [
    "/etc/bmcfido/get_client_session_status.sh",
    path.join(__dirname, "get_client_session_status.sh"),
  ];

  return scriptCandidates.find((scriptPath) => fs.existsSync(scriptPath));
}

function normalizeNumber(value, fallback = null) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function handler(req, res) {
  const scriptPath = getStatusScriptPath();
  const clientIp = getClientIP(req);

  if (!scriptPath) {
    return res.status(500).json({
      status: -1,
      message: "Client session status script not found",
    });
  }

  return execFile("/bin/sh", [scriptPath, clientIp], (error, stdout, stderr) => {
    const output = String(stdout || "").trim();

    if (error && !output) {
      return res.status(500).json({
        status: -1,
        message: stderr || error.message || "Unable to load client session status",
      });
    }

    try {
      const payload = JSON.parse(output || "{}");
      const session = payload && payload.session ? payload.session : null;
      const remainingSeconds = session
        ? normalizeNumber(session.remaining_seconds, null)
        : null;

      if (session) {
        payload.session = {
          ip: session.ip || clientIp,
          user: session.user || "unknown",
          timeout: normalizeNumber(session.timeout, 0),
          expiresAt: normalizeNumber(session.expires_at, null),
          remainingSeconds,
          countdownEnabled:
            session.countdown_enabled === true ||
            String(session.countdown_enabled) === "true",
          isWarning:
            remainingSeconds !== null &&
            remainingSeconds > 0 &&
            remainingSeconds <= WARNING_THRESHOLD_SECONDS,
          isExpired: remainingSeconds === 0,
        };
      }

      payload.clientIp = clientIp;
      payload.warningThresholdSeconds = WARNING_THRESHOLD_SECONDS;
      return res.json(payload);
    } catch (parseError) {
      return res.status(500).json({
        status: -1,
        message: "Invalid JSON output from get_client_session_status.sh",
        error: parseError.message,
        raw: output,
      });
    }
  });
}

module.exports = { handler };
