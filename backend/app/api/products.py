import time
from decimal import Decimal

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_db_session
from app.models.product import Product
from app.schemas.product import (
    ProductCreate,
    ProductListResponse,
    ProductResponse,
    ProductUpdate,
)

router = APIRouter(prefix="/products", tags=["products"])


@router.get("", response_model=ProductListResponse)
async def list_products(
    category: str | None = Query(None),
    min_price: Decimal | None = Query(None, ge=0),
    max_price: Decimal | None = Query(None, ge=0),
    in_stock: bool | None = Query(None),
    search: str | None = Query(None),
    sort: str = Query("featured", pattern="^(featured|low|high|name)$"),
    page: int = Query(1, ge=1),
    page_size: int = Query(12, ge=1, le=100),
    session: AsyncSession = Depends(get_db_session),
) -> ProductListResponse:
    query = select(Product)
    count_query = select(func.count(Product.id))

    if category and category != "All":
        query = query.where(Product.category == category)
        count_query = count_query.where(Product.category == category)

    if min_price is not None:
        query = query.where(Product.price >= min_price)
        count_query = count_query.where(Product.price >= min_price)

    if max_price is not None:
        query = query.where(Product.price <= max_price)
        count_query = count_query.where(Product.price <= max_price)

    if in_stock is not None:
        query = query.where(Product.stock == in_stock)
        count_query = count_query.where(Product.stock == in_stock)

    if search:
        search_term = f"%{search.lower()}%"
        query = query.where(
            or_(
                Product.name.ilike(search_term),
                Product.category.ilike(search_term),
            )
        )
        count_query = count_query.where(
            or_(
                Product.name.ilike(search_term),
                Product.category.ilike(search_term),
            )
        )

    if sort == "low":
        query = query.order_by(Product.price.asc())
    elif sort == "high":
        query = query.order_by(Product.price.desc())
    elif sort == "name":
        query = query.order_by(Product.name.asc())
    else:
        query = query.order_by(Product.id.asc())

    total_result = await session.execute(count_query)
    total = total_result.scalar_one()

    query = query.offset((page - 1) * page_size).limit(page_size)
    result = await session.execute(query)
    products = result.scalars().all()

    return ProductListResponse(
        products=[ProductResponse.model_validate(p) for p in products],
        total=total,
        page=page,
        page_size=page_size,
    )


@router.get("/categories", response_model=list[str])
async def get_categories(session: AsyncSession = Depends(get_db_session)) -> list[str]:
    result = await session.execute(select(Product.category).distinct())
    categories = result.scalars().all()
    return ["All"] + sorted(categories)


@router.get("/{product_id}", response_model=ProductResponse)
async def get_product(product_id: int, session: AsyncSession = Depends(get_db_session)) -> ProductResponse:
    result = await session.execute(select(Product).where(Product.id == product_id))
    product = result.scalar_one_or_none()
    if not product:
        raise HTTPException(status_code=404, detail="Product not found")
    return ProductResponse.model_validate(product)


@router.post("", response_model=ProductResponse, status_code=201)
async def create_product(
    product_data: ProductCreate, session: AsyncSession = Depends(get_db_session)
) -> ProductResponse:
    now = int(time.time())
    product = Product(
        **product_data.model_dump(),
        created_at=now,
        updated_at=now,
    )
    session.add(product)
    await session.flush()
    await session.refresh(product)
    return ProductResponse.model_validate(product)


@router.patch("/{product_id}", response_model=ProductResponse)
async def update_product(
    product_id: int,
    product_data: ProductUpdate,
    session: AsyncSession = Depends(get_db_session),
) -> ProductResponse:
    result = await session.execute(select(Product).where(Product.id == product_id))
    product = result.scalar_one_or_none()
    if not product:
        raise HTTPException(status_code=404, detail="Product not found")

    update_data = product_data.model_dump(exclude_unset=True)
    for field, value in update_data.items():
        setattr(product, field, value)
    product.updated_at = int(time.time())

    await session.flush()
    await session.refresh(product)
    return ProductResponse.model_validate(product)


@router.delete("/{product_id}", status_code=204)
async def delete_product(product_id: int, session: AsyncSession = Depends(get_db_session)) -> None:
    result = await session.execute(select(Product).where(Product.id == product_id))
    product = result.scalar_one_or_none()
    if not product:
        raise HTTPException(status_code=404, detail="Product not found")
    await session.delete(product)
