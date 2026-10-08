"""Route modules, one per API area."""

from . import actions, chat, dashboard, health, sql

ROUTERS = [health.router, sql.router, actions.router, dashboard.router, chat.router]
