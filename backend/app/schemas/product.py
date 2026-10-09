from decimal import Decimal

from pydantic import BaseModel, ConfigDict, Field


class ProductBase(BaseModel):
    name: str = Field(..., min_length=1, max_length=255)
    category: str = Field(..., min_length=1, max_length=100)
    price: Decimal = Field(..., ge=0, decimal_places=2)
    stock: bool = True
    tag: str | None = Field(None, max_length=50)
    image_url: str = Field(..., min_length=1)
    description: str | None = None


class ProductCreate(ProductBase):
    pass


class ProductUpdate(BaseModel):
    name: str | None = Field(None, min_length=1, max_length=255)
    category: str | None = Field(None, min_length=1, max_length=100)
    price: Decimal | None = Field(None, ge=0, decimal_places=2)
    stock: bool | None = None
    tag: str | None = Field(None, max_length=50)
    image_url: str | None = Field(None, min_length=1)
    description: str | None = None


class ProductResponse(ProductBase):
    model_config = ConfigDict(from_attributes=True, json_encoders={Decimal: float})

    id: int
    created_at: int
    updated_at: int


class ProductListResponse(BaseModel):
    products: list[ProductResponse]
    total: int
    page: int
    page_size: int
