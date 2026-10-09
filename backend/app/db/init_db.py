import asyncio
import logging
import time
from decimal import Decimal

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import close_db, init_db, session_scope
from app.models.product import Product

logger = logging.getLogger(__name__)

PRODUCTS = [
    {
        "id": 1,
        "name": "Aero Chronograph",
        "category": "Accessories",
        "price": Decimal("2999.00"),
        "stock": True,
        "tag": "BESTSELLER",
        "image_url": "https://images.unsplash.com/photo-1523275335684-37898b6baf30?auto=format&fit=crop&w=900&q=90",
        "description": "Premium chronograph watch with sapphire crystal and stainless steel bracelet.",
    },
    {
        "id": 2,
        "name": "Urban Leather Tote",
        "category": "Fashion",
        "price": Decimal("2499.00"),
        "stock": True,
        "tag": "NEW",
        "image_url": "https://images.unsplash.com/photo-1584917865442-de89df76afd3?auto=format&fit=crop&w=900&q=90",
        "description": "Handcrafted genuine leather tote with laptop compartment.",
    },
    {
        "id": 3,
        "name": "Studio Headphones",
        "category": "Electronics",
        "price": Decimal("3999.00"),
        "stock": True,
        "tag": "POPULAR",
        "image_url": "https://images.unsplash.com/photo-1505740420928-5e560c06d30e?auto=format&fit=crop&w=900&q=90",
        "description": "Over-ear wireless headphones with active noise cancellation.",
    },
    {
        "id": 4,
        "name": "Everyday Sneakers",
        "category": "Fashion",
        "price": Decimal("3299.00"),
        "stock": True,
        "tag": "SALE",
        "image_url": "https://images.unsplash.com/photo-1542291026-7eec264c27ff?auto=format&fit=crop&w=900&q=90",
        "description": "Lightweight breathable sneakers for daily wear.",
    },
    {
        "id": 5,
        "name": "Ceramic Desk Set",
        "category": "Home",
        "price": Decimal("1299.00"),
        "stock": True,
        "tag": "NEW",
        "image_url": "https://images.unsplash.com/photo-1494438639946-1ebd1d20bf85?auto=format&fit=crop&w=900&q=90",
        "description": "Minimalist ceramic organizer set for desk essentials.",
    },
    {
        "id": 6,
        "name": "Smart Speaker",
        "category": "Electronics",
        "price": Decimal("4499.00"),
        "stock": True,
        "tag": "SMART",
        "image_url": "https://images.unsplash.com/photo-1589003077984-894e133dabab?auto=format&fit=crop&w=900&q=90",
        "description": "Voice-controlled smart speaker with premium audio.",
    },
    {
        "id": 7,
        "name": "Classic Sunglasses",
        "category": "Accessories",
        "price": Decimal("1799.00"),
        "stock": True,
        "tag": "TRENDING",
        "image_url": "https://images.unsplash.com/photo-1511499767150-a48a237f0083?auto=format&fit=crop&w=900&q=90",
        "description": "UV400 polarized lenses with acetate frame.",
    },
    {
        "id": 8,
        "name": "Linen Home Throw",
        "category": "Home",
        "price": Decimal("1899.00"),
        "stock": True,
        "tag": "SALE",
        "image_url": "https://images.unsplash.com/photo-1583845112203-454c7b6e6e31?auto=format&fit=crop&w=900&q=90",
        "description": "100% European linen throw blanket.",
    },
    {
        "id": 9,
        "name": "Minimal Backpack",
        "category": "Fashion",
        "price": Decimal("2199.00"),
        "stock": True,
        "tag": "NEW",
        "image_url": "https://images.unsplash.com/photo-1553062407-98eeb64c6a62?auto=format&fit=crop&w=900&q=90",
        "description": "Water-resistant backpack with laptop sleeve.",
    },
    {
        "id": 10,
        "name": "Premium Camera",
        "category": "Electronics",
        "price": Decimal("4999.00"),
        "stock": True,
        "tag": "FEATURED",
        "image_url": "https://images.unsplash.com/photo-1516035069371-29a1b244cc32?auto=format&fit=crop&w=900&q=90",
        "description": "Mirrorless camera with 24MP sensor and 4K video.",
    },
    {
        "id": 11,
        "name": "Classic Wallet",
        "category": "Accessories",
        "price": Decimal("999.00"),
        "stock": True,
        "tag": "POPULAR",
        "image_url": "https://images.unsplash.com/photo-1627123424574-724758594e93?auto=format&fit=crop&w=900&q=90",
        "description": "Slim bifold wallet in full-grain leather.",
    },
    {
        "id": 12,
        "name": "Modern Table Lamp",
        "category": "Home",
        "price": Decimal("1599.00"),
        "stock": True,
        "tag": "HOME",
        "image_url": "https://images.unsplash.com/photo-1507473885765-e6ed057f782c?auto=format&fit=crop&w=900&q=90",
        "description": "Dimmable LED table lamp with touch control.",
    },
]


async def seed_products(session: AsyncSession) -> None:
    for product_data in PRODUCTS:
        result = await session.execute(
            select(Product).where(Product.id == product_data["id"])
        )
        existing = result.scalar_one_or_none()
        if existing:
            continue

        product = Product(
            id=product_data["id"],
            name=product_data["name"],
            category=product_data["category"],
            price=product_data["price"],
            stock=product_data["stock"],
            tag=product_data["tag"],
            image_url=product_data["image_url"],
            description=product_data["description"],
            created_at=int(time.time()),
            updated_at=int(time.time()),
        )
        session.add(product)
        logger.info("Added product: %s", product.name)

    await session.commit()
    logger.info("Seeding complete!")


async def main() -> None:
    init_db()
    async with session_scope() as session:
        await seed_products(session)
    await close_db()


if __name__ == "__main__":
    asyncio.run(main())
