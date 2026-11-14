import initSqlJs from 'sql.js';
import path from 'path';
import fs from 'fs';

class Database {
    db!: any;
    public ready: Promise<void>;
    private dbPath: string;

    constructor() {
        this.dbPath = path.resolve(__dirname, './database.sqlite');
        this.ready = this.initDb();
    }

    private async initDb() {
        const SQL = await initSqlJs();

        let fileBuffer: Uint8Array | null = null;
        if (fs.existsSync(this.dbPath)) {
            const stats = fs.statSync(this.dbPath);
            if (stats.size > 0) {
                fileBuffer = new Uint8Array(fs.readFileSync(this.dbPath));
            }
        }

        if (fileBuffer) {
            this.db = new SQL.Database(fileBuffer);
            console.log('Connected to existing SQLite database (WASM)');
        } else {
            this.db = new SQL.Database();
            console.log('Created new SQLite database (WASM)');
        }

        // Always ensure tables exist
        this.createTables();
        this.save();
    }

    private createTables() {
        // Users table
        this.db.run(`CREATE TABLE IF NOT EXISTS users (
            id TEXT PRIMARY KEY,
            username TEXT UNIQUE,
            devices TEXT,
            isAdmin INTEGER DEFAULT 0
        )`);

        // Sessions table
        this.db.run(`CREATE TABLE IF NOT EXISTS sessions (
            _id TEXT PRIMARY KEY,
            userId TEXT,
            rhid TEXT,
            gatewayHash TEXT,
            fasAuthentication INTEGER DEFAULT 0,
            expireAt INTEGER
        )`);
    }

    public save() {
        const data = this.db.export();
        const buffer = new Uint8Array(data);
        fs.writeFileSync(this.dbPath, buffer);
    }

    public get() {
        const handleParams = (params: any, callback: any) => {
            let actualCallback = callback;
            let actualParams = params || [];

            if (typeof params === 'function') {
                actualCallback = params;
                actualParams = [];
            }

            // sql.js does not support 'undefined', convert to 'null'
            if (Array.isArray(actualParams)) {
                actualParams = actualParams.map(p => p === undefined ? null : p);
            } else if (typeof actualParams === 'object' && actualParams !== null) {
                for (const key in actualParams) {
                    if (actualParams[key] === undefined) actualParams[key] = null;
                }
            }

            return { actualCallback, actualParams };
        };

        return {
            run: (sql: string, params?: any, callback?: any) => {
                const { actualCallback, actualParams } = handleParams(params, callback);
                try {
                    this.db.run(sql, actualParams);
                    this.save();
                    if (actualCallback) actualCallback(null);
                } catch (err: any) {
                    if (actualCallback) actualCallback(err);
                }
            },
            get: (sql: string, params?: any, callback?: any) => {
                const { actualCallback, actualParams } = handleParams(params, callback);
                try {
                    const stmt = this.db.prepare(sql);
                    stmt.bind(actualParams);
                    const row = stmt.step() ? stmt.getAsObject() : null;
                    stmt.free();
                    if (actualCallback) actualCallback(null, row);
                } catch (err: any) {
                    if (actualCallback) actualCallback(err, null);
                }
            },
            all: (sql: string, params?: any, callback?: any) => {
                const { actualCallback, actualParams } = handleParams(params, callback);
                try {
                    const stmt = this.db.prepare(sql);
                    stmt.bind(actualParams);
                    const rows = [];
                    while (stmt.step()) {
                        rows.push(stmt.getAsObject());
                    }
                    stmt.free();
                    if (actualCallback) actualCallback(null, rows);
                } catch (err: any) {
                    if (actualCallback) actualCallback(err, []);
                }
            },
            serialize: (callback: () => void) => {
                callback();
            }
        };
    }

    public close() {
        this.db.close();
    }
}

export const dbRequest = new Database();
