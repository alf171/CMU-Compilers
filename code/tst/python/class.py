# simple class example
class Car:
    def __init__(self, name: str, speed: int) -> None:
        self.name = name 
        self.speed = speed

    def print_speed(self) -> None:
        # print(f"we are driving a {self.name} at {self.speed} mph")
        print(self.speed)

audi = Car("audi", 30)
audi.print_speed()
