from calculator import add, is_adult, calculate_discount

def test_add():
    assert add(2, 3) == 5

def test_is_adult():
    assert is_adult(20) is True
    assert is_adult(15) is False

def test_calculate_discount():
    assert calculate_discount(150, True) == 120.0
    assert calculate_discount(80, True) == 80.0
    assert calculate_discount(150, False) == 150.0