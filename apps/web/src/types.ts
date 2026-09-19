export type Task = {
  id: string;
  title: string;
  dueDate: string | null;
  important: boolean;
  completed: boolean;
  createdAt: string;
  updatedAt: string;
};
