def add(a: int, b: int) -> int:
    return a + b

def is_adult(age: int) -> bool:
    if age >= 18:
        return True
    return False

def calculate_discount(price: float, is_member: bool) -> float:
    if is_member and price > 100:
        return price * 0.8  # 20% discount
    return price