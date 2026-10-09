import time
from collections.abc import AsyncGenerator
from decimal import Decimal

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient

from app.db.session import create_tables, init_db, session_scope
from app.main import create_app
from app.models.product import Product


@pytest.fixture(scope="session")
def app() -> FastAPI:
    return create_app()


@pytest.fixture(scope="session")
async def client(app: FastAPI) -> AsyncGenerator[AsyncClient, None]:
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        yield ac


@pytest.fixture(autouse=True)
async def setup_test_db() -> AsyncGenerator[None, None]:
    """Initialize DB and create tables for each test."""
    init_db()
    await create_tables()
    yield


def get_test_product_id() -> int:
    """Generate a unique test product ID."""
    return int(f"999{int(time.time() * 1000) % 1000000}")


async def create_test_product() -> int:
    """Helper to create a test product."""
    product_id = get_test_product_id()
    async with session_scope() as session:
        product = Product(
            id=product_id,
            name="Test Product",
            category="Test",
            price=Decimal("100.00"),
            stock=True,
            tag="TEST",
            image_url="https://example.com/test.jpg",
            description="Test product",
            created_at=1234567890,
            updated_at=1234567890,
        )
        session.add(product)
        await session.commit()
        await session.refresh(product)
        return product_id


class TestHealthEndpoints:
    async def test_health_check(self, client: AsyncClient) -> None:
        response = await client.get("/api/health")
        assert response.status_code == 200
        data = response.json()
        assert data["status"] in ["healthy", "degraded"]
        assert "version" in data
        assert "database" in data

    async def test_detailed_health_check(self, client: AsyncClient) -> None:
        response = await client.get("/api/health/detailed")
        assert response.status_code == 200
        data = response.json()
        assert "checks" in data
        assert "database" in data["checks"]
        assert "api" in data["checks"]


class TestProductEndpoints:
    async def test_list_products(self, client: AsyncClient) -> None:
        await create_test_product()
        response = await client.get("/api/products")
        assert response.status_code == 200
        data = response.json()
        assert "products" in data
        assert "total" in data
        assert data["total"] >= 1

    async def test_list_products_with_filters(self, client: AsyncClient) -> None:
        await create_test_product()
        response = await client.get("/api/products?category=Test&max_price=200")
        assert response.status_code == 200
        data = response.json()
        for product in data["products"]:
            assert product["category"] == "Test"
            assert product["price"] <= 200

    async def test_get_product(self, client: AsyncClient) -> None:
        product_id = await create_test_product()
        response = await client.get(f"/api/products/{product_id}")
        assert response.status_code == 200
        data = response.json()
        assert data["id"] == product_id
        assert data["name"] == "Test Product"

    async def test_get_nonexistent_product(self, client: AsyncClient) -> None:
        response = await client.get("/api/products/999999")
        assert response.status_code == 404

    async def test_get_categories(self, client: AsyncClient) -> None:
        await create_test_product()
        response = await client.get("/api/products/categories")
        assert response.status_code == 200
        data = response.json()
        assert "All" in data
        assert "Test" in data


class TestOrderEndpoints:
    async def test_create_order(self, client: AsyncClient) -> None:
        product_id = await create_test_product()
        order_data = {
            "user_name": "Test User",
            "user_email": "test@example.com",
            "phone": "9876543210",
            "address": "123 Test Street",
            "city": "Test City",
            "pin_code": "123456",
            "payment_method": "cod",
            "items": [{"product_id": product_id, "quantity": 2}]
        }
        response = await client.post("/api/orders", json=order_data)
        assert response.status_code == 201
        data = response.json()
        assert data["user_name"] == "Test User"
        assert data["user_email"] == "test@example.com"
        assert len(data["items"]) == 1
        assert data["items"][0]["quantity"] == 2
        assert data["subtotal"] == "200.00"
        assert data["status"] == "confirmed"

    async def test_create_order_invalid_product(self, client: AsyncClient) -> None:
        order_data = {
            "user_name": "Test User",
            "user_email": "test@example.com",
            "phone": "9876543210",
            "address": "123 Test Street",
            "city": "Test City",
            "pin_code": "123456",
            "payment_method": "cod",
            "items": [{"product_id": 999999, "quantity": 1}]
        }
        response = await client.post("/api/orders", json=order_data)
        assert response.status_code == 404

    async def test_create_order_empty_items(self, client: AsyncClient) -> None:
        order_data = {
            "user_name": "Test User",
            "user_email": "test@example.com",
            "phone": "9876543210",
            "address": "123 Test Street",
            "city": "Test City",
            "pin_code": "123456",
            "payment_method": "cod",
            "items": []
        }
        response = await client.post("/api/orders", json=order_data)
        assert response.status_code == 400

    async def test_get_order(self, client: AsyncClient) -> None:
        product_id = await create_test_product()
        # First create an order
        order_data = {
            "user_name": "Test User",
            "user_email": "test@example.com",
            "phone": "9876543210",
            "address": "123 Test Street",
            "city": "Test City",
            "pin_code": "123456",
            "payment_method": "cod",
            "items": [{"product_id": product_id, "quantity": 1}]
        }
        create_resp = await client.post("/api/orders", json=order_data)
        assert create_resp.status_code == 201
        order_id = create_resp.json()["order_id"]

        # Now get it
        response = await client.get(f"/api/orders/{order_id}")
        assert response.status_code == 200
        data = response.json()
        assert data["order_id"] == order_id

    async def test_list_orders(self, client: AsyncClient) -> None:
        response = await client.get("/api/orders?limit=5")
        assert response.status_code == 200
        data = response.json()
        assert isinstance(data, list)
