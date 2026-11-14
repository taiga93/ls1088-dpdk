import type { AuthenticatorDevice } from '@simplewebauthn/typescript-types';
import { dbRequest } from './database';
import { sessionDatabase } from './session';
import { Buffer } from 'buffer';

export class User {
  id: string;
  username: string;
  devices: AuthenticatorDevice[];
  isAdmin: Boolean;

  constructor(id: string, username: string, devices: AuthenticatorDevice[] = [], isAdmin: Boolean = false) {
    this.id = id;
    this.username = username;
    this.devices = devices;
    this.isAdmin = isAdmin;
  }
}

class UserDatabase {

  constructor() {
  }

  private parseDevices(devicesJson: string): AuthenticatorDevice[] {
    const devices = JSON.parse(devicesJson);
    return devices.map((dev: any) => ({
      ...dev,
      credentialID: Buffer.isBuffer(dev.credentialID) ? dev.credentialID : Buffer.from(dev.credentialID.data || dev.credentialID),
      credentialPublicKey: Buffer.isBuffer(dev.credentialPublicKey) ? dev.credentialPublicKey : Buffer.from(dev.credentialPublicKey.data || dev.credentialPublicKey),
    }));
  }

  /**
   * Get all users
   */
  public async getRegisteredUsers(): Promise<RegisteredUser[]> {
    return new Promise((resolve, reject) => {
      dbRequest.get().all("SELECT * FROM users", async (err: Error | null, rows: any[]) => {
        if (err) return reject(err);

        const users = rows.map(row => new User(
          row.id,
          row.username,
          this.parseDevices(row.devices),
          !!row.isAdmin
        ));

        const registeredUsers = await Promise.all(users.map(async (user) => (
          {
            username: user.username,
            nofdevices: user.devices.length,
            activesessions: (await sessionDatabase.getByUserId(user.id)).length,
            isAdmin: user.isAdmin
          }
        )));
        resolve(registeredUsers);
      });
    });
  }

  /**
   * Get user by username
   */
  public async getByUsername(username: string | undefined): Promise<User> {
    return new Promise((resolve, reject) => {
      dbRequest.get().get("SELECT * FROM users WHERE username = ?", [username], (err: Error | null, row: any) => {
        if (err) return reject(err);
        if (!row) return resolve(undefined as any);
        resolve(new User(
          row.id,
          row.username,
          this.parseDevices(row.devices),
          !!row.isAdmin
        ));
      });
    });
  }

  /**
   * Get user by user ID
   */
  public async getById(id: string | undefined): Promise<User> {
    return new Promise((resolve, reject) => {
      dbRequest.get().get("SELECT * FROM users WHERE id = ?", [id], (err: Error | null, row: any) => {
        if (err) return reject(err);
        if (!row) return resolve(undefined as any);
        resolve(new User(
          row.id,
          row.username,
          this.parseDevices(row.devices),
          !!row.isAdmin
        ));
      });
    });
  }

  /**
   * Get allowed credentials by username
   */
  public async getAllowCredentialsByUsername(username: string | undefined): Promise<PublicKeyCredentialDescriptor[]> {

    const user: User = await this.getByUsername(username);

    return user ? user.devices.map(dev => ({
      id: dev.credentialID as unknown as BufferSource, // Fix type mismatch
      type: 'public-key',
      transports: dev.transports,
    })) : [];
  }

  /**
   * Add a new user to the database 
   */
  public async registerNewUser(userId: string, username: string, device: AuthenticatorDevice) {
    const devices = JSON.stringify([device]);
    return new Promise<void>((resolve, reject) => {
      dbRequest.get().run(
        "INSERT INTO users (id, username, devices, isAdmin) VALUES (?, ?, ?, ?)",
        [userId, username, devices, 0],
        (err: Error | null) => {
          if (err) reject(err);
          else resolve();
        }
      );
    });
  }

  /**
   * Add an authenticator device to user
   */
  public async addDeviceToUser(userId: string, username: string, newDevice: AuthenticatorDevice) {
    var user: User = await this.getByUsername(username);
    if (user) {
      // Check if the device is already registered
      const existingDevice = user.devices.find(device => {
        // Basic comparison. Ideally compare base64 strings of IDs
        const id1 = Buffer.isBuffer(device.credentialID) ? device.credentialID : Buffer.from((device.credentialID as any).data || device.credentialID);
        const id2 = Buffer.isBuffer(newDevice.credentialID) ? newDevice.credentialID : Buffer.from((newDevice.credentialID as any).data || newDevice.credentialID);
        return Buffer.compare(id1, id2) === 0;
      });

      if (!existingDevice) {
        user.devices.push(newDevice);
        const devicesStr = JSON.stringify(user.devices);
        await new Promise<void>((resolve, reject) => {
          dbRequest.get().run("UPDATE users SET devices = ? WHERE id = ?", [devicesStr, user.id], (err: Error | null) => {
            if (err) reject(err);
            else resolve();
          });
        });
      }
    } else {
      // Create new user if it does not already exist
      await this.registerNewUser(userId, username, newDevice);
    }
  }

  /**
   * Make a user admin or remove admin rights
   */
  public async updateAdminUser(username: string, isAdmin: Boolean) {
    return new Promise<void>((resolve, reject) => {
      dbRequest.get().run("UPDATE users SET isAdmin = ? WHERE username = ?", [isAdmin ? 1 : 0, username], (err: Error | null) => {
        if (err) reject(err);
        else resolve();
      });
    });
  }

  /**
   * Generate a new random user id
   */
  public async generateRandomUserId(): Promise<string> {
    let outString: string = '';
    const inOptions: string = 'abcdefghijklmnopqrstuvwxyz0123456789';

    for (let i = 0; i < 32; i++)
      outString += inOptions.charAt(Math.floor(Math.random() * inOptions.length));

    const existing = await this.getById(outString);
    return existing ? this.generateRandomUserId() : outString;
  }

  /**
   * Checks if at least one administrator is registered
   */
  public async isAdministratorConfigured(): Promise<boolean> {
    return new Promise((resolve, reject) => {
      dbRequest.get().get("SELECT COUNT(*) as count FROM users WHERE isAdmin = 1", (err: Error | null, row: any) => {
        if (err) reject(err);
        else resolve(row.count > 0);
      });
    });
  }

  /**
   * Delete a user and their associated sessions
   */
  public async deleteUser(username: string) {
    const user: User = await this.getByUsername(username);
    if (!user) throw new Error("User not found");

    return new Promise<void>((resolve, reject) => {
      // Use a transaction or sequential deletes
      dbRequest.get().serialize(() => {
        dbRequest.get().run("DELETE FROM sessions WHERE userId = ?", [user.id], (err: Error | null) => {
          if (err) console.error(`Error deleting sessions for user ${username}:`, err);
        });
        dbRequest.get().run("DELETE FROM users WHERE id = ?", [user.id], (err: Error | null) => {
          if (err) reject(err);
          else resolve();
        });
      });
    });
  }
}

export const userDatabase = new UserDatabase();

export declare type RegisteredUser = {
  username?: string,
  nofdevices?: number,
  activesessions?: number,
  isAdmin?: Boolean
};

export declare type AdminUser = {
  username: string,
  isAdmin: Boolean
}

module.exports = { User, userDatabase };