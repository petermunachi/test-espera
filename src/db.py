"""Database helpers — embedded SQL fixture for AST + sqlparser analysis."""

def cleanup_accounts(cursor):
    cursor.execute("DELETE FROM accounts")
