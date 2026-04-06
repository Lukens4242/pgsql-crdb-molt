import csv
import datetime as dt
import decimal
import random
import time
import uuid
import traceback
from concurrent.futures import ThreadPoolExecutor
from string import ascii_lowercase
from time import sleep

import psycopg2
from psycopg2 import OperationalError, errors
from psycopg2.extras import execute_batch, register_uuid
from psycopg2.pool import ThreadedConnectionPool

import argparse
import threading

parser = argparse.ArgumentParser()
parser.add_argument("--dsn", required=True, help="PostgreSQL DSN connection string")
parser.add_argument("--generate", action="store_true", help="Generate order CSV file")
parser.add_argument("--insert", action="store_true", help="Insert orders from CSV")
parser.add_argument("--fill", action="store_true", help="Fill orders")
parser.add_argument("--delete", action="store_true", help="Delete completed orders")
parser.add_argument("--orders", type=int, default=10_000, help="Total orders to generate (default: 10000)")
parser.add_argument("--batch-size", type=int, default=8, help="Batch size for inserts (default: 8)")
parser.add_argument("--threads", type=int, default=8, help="Number of threads (default: 8)")
opt = parser.parse_args()
DB_URI = opt.dsn

ORDERS_FILE = "orders_1m.csv"
TOTAL_ORDERS = opt.orders
BATCH_SIZE = opt.batch_size
THREADS = opt.threads

register_uuid()

def run_with_retries(fn, max_retries=5, backoff_base=0.1):
    attempt = 0
    while True:
        try:
            return fn()
        except (errors.SerializationFailure, errors.DeadlockDetected, errors.StatementCompletionUnknown) as e:
            if attempt >= max_retries:
                raise
            wait = backoff_base * (2 ** attempt)
            print(f"⚠️ Retryable transactional error ({e.__class__.__name__}), retrying in {wait:.2f}s (attempt {attempt + 1})...")
            sleep(wait)
            attempt += 1
        except psycopg2.OperationalError as e:
            sqlstate = getattr(e, 'pgcode', None)
            msg = str(e).lower()
            retryable_sqlstate_classes = ('08', '57')
            if sqlstate and sqlstate[:2] in retryable_sqlstate_classes:
                if attempt >= max_retries:
                    raise
                wait = backoff_base * (2 ** attempt)
                print(f"⚠️ Retryable OperationalError with SQLSTATE {sqlstate}, retrying in {wait:.2f}s (attempt {attempt + 1})...")
                sleep(wait)
                attempt += 1
                continue
            elif "ssl syscall error: eof detected" in msg:
                if attempt >= max_retries:
                    raise
                wait = backoff_base * (2 ** attempt)
                print(f"⚠️ Retryable OperationalError SSL SYSCALL EOF detected, retrying in {wait:.2f}s (attempt {attempt + 1})...")
                sleep(wait)
                attempt += 1
                continue
            else:
                raise
        except Exception:
            raise

class Orders:
    def __init__(self, conn_string):
        self.conn_string = conn_string
        self.symbol = "".join(random.choices(ascii_lowercase, k=3))
        self.pool = ThreadedConnectionPool(1, THREADS * 2, dsn=self.conn_string)
        self._conn_semaphore = threading.Semaphore(THREADS)
        self.processed_count = 0
        self.total_orders = 0
        self.progress_lock = threading.Lock()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close_pool()
        return False

    def get_conn(self):
        if not self._conn_semaphore.acquire(timeout=30):
            raise OperationalError("❌ Timed out waiting for a connection from the pool.")
        retries = 0
        max_retries = 5
        while retries <= max_retries:
            conn = None
            try:
                conn = self.pool.getconn()
                if conn.closed:
                    raise OperationalError("Connection is already closed.")
                with conn.cursor() as cur:
                    cur.execute("SELECT 1")
                return conn
            except Exception as e:
                if conn is not None:
                    self.pool.putconn(conn, close=True)
                retries += 1
                wait = 0.1 * (2 ** retries)
                print(f"⚠️ Retrying get_conn() in {wait:.2f}s due to connection error (attempt {retries})")
                sleep(wait)
        self._conn_semaphore.release()
        raise OperationalError("❌ Failed to get a working DB connection after retries.")

    def put_conn(self, conn):
        try:
            self.pool.putconn(conn)
        except Exception as e:
            print(f"⚠️ Failed to return connection: {e}")
        finally:
            self._conn_semaphore.release()

    def close_pool(self):
        self.pool.closeall()

    def setup_schema(self):
        def txn():
            conn = self.get_conn()
            try:
                with conn:
                    with conn.cursor() as cur:
                        cur.execute("CREATE EXTENSION IF NOT EXISTS pgcrypto;")
                        cur.execute("""
                            CREATE TABLE IF NOT EXISTS orders (
                                account_id BIGINT,
                                order_id UUID PRIMARY KEY,
                                symbol TEXT,
                                order_started TIMESTAMPTZ,
                                order_completed TIMESTAMPTZ,
                                total_shares_purchased INT,
                                total_cost_of_order DECIMAL,
                                attr_0 TEXT, attr_1 TEXT, attr_2 TEXT
                            );
                        """)
                        cur.execute("""
                            CREATE TABLE IF NOT EXISTS order_fills (
                                fill_id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
                                order_id UUID ,
                                account_id BIGINT,
                                symbol TEXT,
                                fill_time TIMESTAMPTZ,
                                shares_filled INT,
                                total_cost_of_fill DECIMAL,
                                price_at_time_of_fill DECIMAL,
                                fill_attr_0 TEXT, fill_attr_1 TEXT, fill_attr_2 TEXT
                            );
                        """)
            finally:
                self.put_conn(conn)
        run_with_retries(txn)
        print("✅ Schema initialized.")

    def generate_order(self):
        return (
            random.randint(1, 1_000_000_000),
            uuid.uuid4(),
            self.symbol,
            dt.datetime.now(dt.timezone.utc).isoformat(),
            "",
            random.randint(1, 1000),
            str(round(decimal.Decimal(random.randrange(100, 10000)) / 100, 2)),
            "foo", "bar", "baz"
        )

    def generate_and_save_orders(self, count=TOTAL_ORDERS):
        print(f"📝 Generating {count:,} random orders into CSV...")
        with open(ORDERS_FILE, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow([
                "account_id", "order_id", "symbol", "order_started",
                "order_completed", "total_shares_purchased", "total_cost_of_order",
                "attr_0", "attr_1", "attr_2"
            ])
            for i in range(count):
                writer.writerow(self.generate_order())
                if (i + 1) % 100_000 == 0:
                    print(f"  Generated {i + 1:,} orders")
        print("✅ CSV file created.")

    def insert_orders_from_file(self):
        print(f"🚚 Inserting orders using {THREADS} threads...")
        with open(ORDERS_FILE, newline="") as f:
            reader = csv.DictReader(f)
            batch = []
            batches = []
            for row in reader:
                order = (
                    int(row["account_id"]),
                    uuid.UUID(row["order_id"]),
                    row["symbol"],
                    row["order_started"],
                    None,
                    int(row["total_shares_purchased"]),
                    row["total_cost_of_order"],
                    row["attr_0"], row["attr_1"], row["attr_2"]
                )
                batch.append(order)
                if len(batch) == BATCH_SIZE:
                    batches.append(batch)
                    batch = []
            if batch:
                batches.append(batch)

        def insert_batch(batch):
            def txn():
                conn = self.get_conn()
                try:
                    with conn:
                        with conn.cursor() as cur:
                            sql = """
                                INSERT INTO orders (
                                    account_id, order_id, symbol, order_started,
                                    order_completed, total_shares_purchased, total_cost_of_order,
                                    attr_0, attr_1, attr_2
                                ) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                            """
                            execute_batch(cur, sql, batch)
                finally:
                    self.put_conn(conn)
            run_with_retries(txn)

        with ThreadPoolExecutor(max_workers=THREADS) as executor:
            executor.map(insert_batch, batches)

        print(f"✅ Inserted {sum(len(b) for b in batches):,} orders.")

    def fill_order(self, order_id, account_id):
        def txn():
            conn = self.get_conn()
            try:
                with conn:
                    with conn.cursor() as cur:
                        cur.execute("SELECT total_shares_purchased FROM orders WHERE order_id = %s FOR UPDATE", (order_id,))
                        row = cur.fetchone()
                        if row is None or row[0] <= 0:
                            return
                        shares_remaining = row[0]
                        shares_filled = random.randint(1, min(100, shares_remaining))
                        total_cost = round(decimal.Decimal(random.randrange(100, 10000)) / 100, 2)
                        price = round(total_cost / shares_filled, 2)
                        now = dt.datetime.now(dt.timezone.utc)
                        cur.execute("""
                            INSERT INTO order_fills (
                                order_id, account_id, symbol, fill_time,
                                shares_filled, total_cost_of_fill, price_at_time_of_fill,
                                fill_attr_0, fill_attr_1, fill_attr_2
                            ) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                        """, (order_id, account_id, self.symbol, now, shares_filled, total_cost, price, "x", "y", "z"))
                        cur.execute("""
                            UPDATE orders SET 
                                total_shares_purchased = total_shares_purchased - %s,
                                total_cost_of_order = total_cost_of_order - %s,
                                order_completed = CASE 
                                    WHEN total_shares_purchased - %s <= 0 THEN %s 
                                    ELSE order_completed 
                                END
                            WHERE order_id = %s
                        """, (shares_filled, total_cost, shares_filled, now, order_id))
            finally:
                self.put_conn(conn)
        run_with_retries(txn)

    def timed_fill(self, args):
        order_id, account_id = args
        self.fill_order(order_id, account_id)
        with self.progress_lock:
            self.processed_count += 1

    def fill_orders_parallel_from_file(self):
        print(f"🛠️ Filling orders in parallel with {THREADS} threads...")

        with open(ORDERS_FILE, newline="") as f:
            reader = csv.DictReader(f)
            order_list = [(uuid.UUID(row["order_id"]), int(row["account_id"])) for row in reader]
            self.total_orders = len(order_list)

        def progress_logger():
            start_time = time.time()
            while self.processed_count < self.total_orders:
                sleep(30)
                with self.progress_lock:
                    elapsed = time.time() - start_time
                    tps = self.processed_count / elapsed if elapsed > 0 else 0
                    remaining = self.total_orders - self.processed_count
                    print(f"📊 Processed: {self.processed_count:,}, Remaining: {remaining:,}, TPS: {tps:.2f}")

        threading.Thread(target=progress_logger, daemon=True).start()

        with ThreadPoolExecutor(max_workers=THREADS) as executor:
            list(executor.map(self.timed_fill, order_list))

        print("✅ All orders filled.")

    def delete_completed_orders(self):
        print(f"🗑️ Deleting completed orders in parallel with {THREADS} threads...")
        conn = self.get_conn()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT order_id FROM orders WHERE order_completed IS NOT NULL")
                completed = [row[0] for row in cur.fetchall()]
        finally:
            self.put_conn(conn)

        if not completed:
            print("No completed orders to delete.")
            return

        random.shuffle(completed)
        self.processed_count = 0
        self.total_orders = len(completed)

        def delete_one(order_id):
            def txn():
                conn = self.get_conn()
                try:
                    with conn:
                        with conn.cursor() as cur:
                            cur.execute("DELETE FROM order_fills WHERE order_id = %s", (order_id,))
                            cur.execute("DELETE FROM orders WHERE order_id = %s", (order_id,))
                finally:
                    self.put_conn(conn)
            run_with_retries(txn)
            with self.progress_lock:
                self.processed_count += 1

        def progress_logger():
            start_time = time.time()
            while self.processed_count < self.total_orders:
                sleep(30)
                with self.progress_lock:
                    elapsed = time.time() - start_time
                    tps = self.processed_count / elapsed if elapsed > 0 else 0
                    remaining = self.total_orders - self.processed_count
                    print(f"📊 Deleted: {self.processed_count:,}, Remaining: {remaining:,}, TPS: {tps:.2f}")

        threading.Thread(target=progress_logger, daemon=True).start()

        with ThreadPoolExecutor(max_workers=THREADS) as executor:
            list(executor.map(delete_one, completed))

        print(f"✅ Deleted {len(completed)} completed orders and their fills.")

def main():
    with Orders(DB_URI) as orders:
        orders.setup_schema()
        if opt.generate:
            orders.generate_and_save_orders()
        if opt.insert:
            orders.insert_orders_from_file()
        if opt.fill:
            orders.fill_orders_parallel_from_file()
        if opt.delete:
            orders.delete_completed_orders()

if __name__ == "__main__":
    main()

