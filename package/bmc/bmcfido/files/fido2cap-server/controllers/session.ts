import { Request, Response, NextFunction } from 'express';
import { exec } from 'child_process';
import { sessionDatabase } from '../models/session';
import { User, userDatabase, RegisteredUser, AdminUser } from '../models/user';
import fs from 'fs';

/**
 * Session authorization Middleware
 */
export function authorizeOnlyAdmin(req: Request, res: Response, next: NextFunction) {

    if (globalThis.administratorConfigured && !req.session.loggedUserId) return res.sendStatus(401);

    if (globalThis.administratorConfigured && !req.session.isAdmin) return res.sendStatus(403);

    next();
}

/**
 * User logout
 */
export async function logoutRoute(req: Request, res: Response, next: NextFunction) {
    // Extract IP for cleanup
    let clientIP = req.headers['x-forwarded-for'] || req.socket.remoteAddress || req.ip;
    if (Array.isArray(clientIP)) clientIP = clientIP[0];
    const cleanIP = clientIP?.replace(/^::ffff:/, ''); // IPv4-mapped IPv6 -> IPv4

    if (cleanIP) {
        exec(`/etc/bmcfido/update_authorized_client.sh del ${cleanIP}`, (error, stdout, stderr) => {
            if (error) console.error(`Logout cleanup error for IP ${cleanIP}: ${error.message}`);
            if (stderr) console.error(`Logout cleanup stderr for IP ${cleanIP}: ${stderr}`);
        });
    }

    await sessionDatabase.logoutSession(req.session.sessionId);
    req.session.loggedUserId = "";
    req.session.sessionId = undefined;
    req.session.isAdmin = false;
    req.session.destroy((error) => {
        if (error) return next(error);
        res.clearCookie('connect.sid');
        res.set('Cache-Control', 'no-store');
        res.redirect(303, '/');
    });
}

/**
 * User details
 */
export async function userDetails(req: Request, res: Response, next: NextFunction) {
    const loggedUserId = req.session.loggedUserId;

    if (loggedUserId && (loggedUserId !== "")) {
        const user: User = await userDatabase.getById(loggedUserId);
        try {

            res.send({ username: user.username, isAdmin: user.isAdmin });

        } catch (error) {
            res.status(500).send("Internal server error");
        }
    } else {
        res.send("You are not logged in!");
    }
}

export async function makeAdmin(req: Request, res: Response, next: NextFunction) {
    const user: AdminUser = req.body;

    try {
        if (user.username) {
            await userDatabase.updateAdminUser(user.username, user.isAdmin);
            // Refresh global flag
            globalThis.administratorConfigured = await userDatabase.isAdministratorConfigured();
        }
    } catch (error) {
        res.status(500).send("Something went wrong!")
    }

    res.status(200).send();
}

export async function registeredUsers(req: Request, res: Response, next: NextFunction) {

    const registered_users: RegisteredUser[] = await userDatabase.getRegisteredUsers();

    res.send({ users: registered_users });

}

export async function deleteUser(req: Request, res: Response, next: NextFunction) {
    const { username } = req.body;

    if (!username) return res.status(400).send("Username is required");

    try {
        await userDatabase.deleteUser(username);

        // Delete IPs associated with this user from the firewall IPSet
        if (fs.existsSync("/etc/bmcfido/update_authorized_client.sh")) {
            exec(`/etc/bmcfido/update_authorized_client.sh del_by_user "${username}"`, (error, stdout, stderr) => {
                if (error) {
                    console.error(`Error executing ipset deletion for user ${username}: ${error.message}`);
                } else {
                    console.log(`Deleted firewall IP rules for user ${username}`);
                }
            });
        }

        // Refresh global flag
        globalThis.administratorConfigured = await userDatabase.isAdministratorConfigured();
        res.status(200).send("User deleted successfully");
    } catch (error) {
        console.error("Error deleting user:", error);
        res.status(500).send("Failed to delete user");
    }
}

module.exports = { authorizeOnlyAdmin, logoutRoute, registeredUsers, userDetails, makeAdmin, deleteUser }