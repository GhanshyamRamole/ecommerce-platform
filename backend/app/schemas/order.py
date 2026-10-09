from decimal import Decimal

from pydantic import BaseModel, ConfigDict, EmailStr, Field


class OrderItemBase(BaseModel):
    product_id: int = Field(..., gt=0)
    quantity: int = Field(..., gt=0)


class OrderItemCreate(OrderItemBase):
    pass


class OrderItemResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    product_id: int
    product_name: str
    product_category: str
    product_price: Decimal
    product_image: str
    quantity: int


class OrderBase(BaseModel):
    user_name: str = Field(..., min_length=2, max_length=255)
    user_email: EmailStr
    phone: str = Field(..., pattern=r"^\d{10}$")
    address: str = Field(..., min_length=5)
    city: str = Field(..., min_length=2, max_length=100)
    pin_code: str = Field(..., pattern=r"^\d{6}$")
    payment_method: str = Field(..., pattern="^(upi|card|cod)$")
    payment_details: str | None = None


class OrderCreate(OrderBase):
    items: list[OrderItemCreate]


class OrderResponse(OrderBase):
    model_config = ConfigDict(from_attributes=True)

    id: int
    order_id: str
    subtotal: Decimal
    status: str
    created_at: int
    updated_at: int
    items: list[OrderItemResponse]
