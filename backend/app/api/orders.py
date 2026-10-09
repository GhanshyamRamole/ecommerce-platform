import time
import uuid
from decimal import Decimal

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.db.session import get_db_session
from app.models.order import Order, OrderItem
from app.models.product import Product
from app.schemas.order import OrderCreate, OrderResponse

router = APIRouter(prefix="/orders", tags=["orders"])


@router.post("", response_model=OrderResponse, status_code=201)
async def create_order(
    order_data: OrderCreate, session: AsyncSession = Depends(get_db_session)
) -> OrderResponse:
    if not order_data.items:
        raise HTTPException(status_code=400, detail="Order must have at least one item")

    # Check for duplicate product IDs in the same order
    product_ids = [item.product_id for item in order_data.items]
    if len(product_ids) != len(set(product_ids)):
        raise HTTPException(status_code=400, detail="Duplicate product IDs in order")

    order_items = []
    subtotal = Decimal("0")

    for item in order_data.items:
        result = await session.execute(select(Product).where(Product.id == item.product_id))
        product = result.scalar_one_or_none()
        if not product:
            raise HTTPException(
                status_code=404, detail=f"Product {item.product_id} not found"
            )
        if not product.stock:
            raise HTTPException(
                status_code=400, detail=f"Product {product.name} is out of stock"
            )
        if item.quantity > 100:  # Reasonable limit
            raise HTTPException(
                status_code=400, detail=f"Quantity for product {product.name} exceeds maximum"
            )

        line_total = product.price * item.quantity
        subtotal += line_total

        order_items.append(
            {
                "product_id": product.id,
                "product_name": product.name,
                "product_category": product.category,
                "product_price": product.price,
                "product_image": product.image_url,
                "quantity": item.quantity,
            }
        )

    now = int(time.time())
    order_id = f"NX{now}{uuid.uuid4().hex[:8].upper()}"

    order = Order(
        order_id=order_id,
        user_name=order_data.user_name,
        user_email=order_data.user_email,
        phone=order_data.phone,
        address=order_data.address,
        city=order_data.city,
        pin_code=order_data.pin_code,
        payment_method=order_data.payment_method,
        payment_details=order_data.payment_details,
        subtotal=subtotal,
        status="confirmed",
        created_at=now,
        updated_at=now,
    )
    session.add(order)
    await session.flush()

    for item_data in order_items:
        order_item = OrderItem(order_id=order.id, **item_data)
        session.add(order_item)

    await session.flush()
    await session.refresh(order)

    # Re-fetch with items loaded
    result = await session.execute(
        select(Order).options(selectinload(Order.items)).where(Order.id == order.id)
    )
    order_with_items = result.scalar_one()

    return OrderResponse.model_validate(order_with_items)


@router.get("/{order_id}", response_model=OrderResponse)
async def get_order(order_id: str, session: AsyncSession = Depends(get_db_session)) -> OrderResponse:
    result = await session.execute(
        select(Order).options(selectinload(Order.items)).where(Order.order_id == order_id)
    )
    order = result.scalar_one_or_none()
    if not order:
        raise HTTPException(status_code=404, detail="Order not found")
    return OrderResponse.model_validate(order)


@router.get("", response_model=list[OrderResponse])
async def list_orders(
    email: str | None = None,
    status: str | None = None,
    limit: int = 20,
    offset: int = 0,
    session: AsyncSession = Depends(get_db_session),
) -> list[OrderResponse]:
    query = (
        select(Order)
        .options(selectinload(Order.items))
        .order_by(Order.created_at.desc())
        .limit(limit)
        .offset(offset)
    )

    if email:
        query = query.where(Order.user_email == email)
    if status:
        query = query.where(Order.status == status)

    result = await session.execute(query)
    orders = result.scalars().all()
    return [OrderResponse.model_validate(o) for o in orders]
