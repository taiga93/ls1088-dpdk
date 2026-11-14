import dotenv from 'dotenv';
import { dbRequest } from './database';

dotenv.config();

const { SESSION_EXPIRE_TIME, CAPTIVE_PORTAL, AUTH_DELAY } = process.env;

declare module "express-session" {
  interface SessionData {
    sessionId: string,
    loggedUserId: string,
    userId: string,
    username: string,
    challenge: string,
    isAdmin: Boolean,
    rhid: string,
    gatewayHash: string,
    originUrl: string
  }
}

export class Session {
  userId: string;
  rhid: string | undefined;
  fasAuthentication: boolean;
  gatewayHash: string | undefined;
  expireAt: number; // Timestamp

  constructor(userId: string, gatewayHash: string | undefined, rhid: string | undefined = "", fasAuthentication: boolean = false, expireAt: number = 0) {
    this.userId = userId;
    this.rhid = rhid;
    this.fasAuthentication = fasAuthentication;
    this.gatewayHash = gatewayHash;
    this.expireAt = expireAt;
  }
}

class SessionDatabase {

  constructor() {
  }

  /**
   * Helper to clean expired sessions (Lazy expiration)
   */
  private async cleanExpiredSessions() {
    const now = Date.now();
    return new Promise<void>((resolve, reject) => {
      dbRequest.get().run("DELETE FROM sessions WHERE expireAt < ?", [now], (err: Error | null) => {
        if (err) console.error("Error cleaning sessions", err);
        resolve();
      });
    });
  }

  /**
   * Get session by user ID
   */
  public async getByUserId(userId: string | undefined): Promise<Session[]> {
    await this.cleanExpiredSessions();
    return new Promise((resolve, reject) => {
      dbRequest.get().all("SELECT * FROM sessions WHERE userId = ?", [userId], (err: Error | null, rows: any[]) => {
        if (err) return reject(err);
        const sessions = rows.map(row => new Session(row.userId, row.gatewayHash, row.rhid, !!row.fasAuthentication, row.expireAt));
        resolve(sessions);
      });
    });
  }

  /**
   * Clear all sessions by GatewayHash
   */
  public async clearGatewaySessions(gatewayHash: string) {
    return new Promise<void>((resolve, reject) => {
      dbRequest.get().run("DELETE FROM sessions WHERE gatewayHash = ?", [gatewayHash], (err: Error | null) => {
        if (err) reject(err);
        else resolve();
      });
    });
  }

  /**
   * Get unauthenticated gateway sessions by GatewayHash
   */
  public async getUnauthenticatedGatewaySessions(gatewayHash: string): Promise<Session[]> {
    await this.cleanExpiredSessions();
    return new Promise((resolve, reject) => {
      dbRequest.get().all("SELECT * FROM sessions WHERE gatewayHash = ? AND fasAuthentication = 0", [gatewayHash], (err: Error | null, rows: any[]) => {
        if (err) return reject(err);
        const sessions = rows.map(row => new Session(row.userId, row.gatewayHash, row.rhid, !!row.fasAuthentication, row.expireAt));
        resolve(sessions);
      });
    });
  }

  /**
   * Mark session as authenticated in the gateway by GatewayHash
   */
  public async markAuthenticatedGatewaySession(gatewayHash: string, rhid: string) {
    return new Promise<void>((resolve, reject) => {
      dbRequest.get().run("UPDATE sessions SET fasAuthentication = 1 WHERE gatewayHash = ? AND rhid = ?", [gatewayHash, rhid], (err: Error | null) => {
        if (err) reject(err);
        else resolve();
      });
    });
  }

  /**
   * Logout user by sessionId
   */
  public async logoutSession(sessionId: string | undefined) {
    if (sessionId && (sessionId != "")) {
      return new Promise<void>((resolve, reject) => {
        dbRequest.get().run("DELETE FROM sessions WHERE _id = ?", [sessionId], (err: Error | null) => {
          if (err) reject(err);
          else resolve();
        });
      });
    }
  }

  public async loginSession(loggedUserId: string | undefined, rhid: string | undefined, gatewayHash: string | undefined): Promise<string> {
    if (loggedUserId && (loggedUserId != "")) {
      const _id = (await import('crypto')).randomUUID(); // Node 16+
      const expireTimeMinutes = SESSION_EXPIRE_TIME ? parseInt(SESSION_EXPIRE_TIME) : 60;
      const expireAt = Date.now() + (expireTimeMinutes * 60 * 1000);

      return new Promise((resolve, reject) => {
        dbRequest.get().run(
          "INSERT INTO sessions (_id, userId, rhid, gatewayHash, fasAuthentication, expireAt) VALUES (?, ?, ?, ?, ?, ?)",
          [_id, loggedUserId, rhid, gatewayHash, 0, expireAt],
          async (err: Error | null) => {
            if (err) return reject(err);

            // wait to confirm authentication for captive portal URL redirection. 5 seconds by default
            if (CAPTIVE_PORTAL) {
              const delay = AUTH_DELAY ? parseInt(AUTH_DELAY) : 5;
              await new Promise(r => setTimeout(r, delay * 1000));
            }

            resolve(_id);
          }
        );
      });
    }
    return "";
  }
}

export const sessionDatabase = new SessionDatabase();

module.exports = { Session, sessionDatabase };